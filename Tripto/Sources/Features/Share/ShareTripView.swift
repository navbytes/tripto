import Supabase
import SwiftData
import SwiftUI
import UIKit

/// The role-aware invite + people screen (BUILD_PLAN.md §5, §7.5;
/// docs/TripAppFamily.jsx's "Invite" screen is the visual reference) —
/// replaces `TripView`'s old "Sharing lands in M3" toast. Reached via
/// `ShareRoute` pushed onto the shared `NavigationStack` (see
/// `TripView.swift`'s doc comment) from the trip hero's share button.
///
/// Three roles, enforced **server-side** via RLS (CLAUDE.md) — this
/// screen's gating (`isOrganizer`) is convenience only: `share_links` and
/// `invites` are organizer-only for *every* verb including SELECT (see
/// `TripShareLink`/`Invite`'s doc comments), so a non-organizer's queries
/// legitimately come back empty regardless of what this screen shows.
struct ShareTripView: View {
    let tripId: UUID

    @Query private var trips: [Trip]
    @Query private var shareLinks: [TripShareLink]
    @Query private var invites: [Invite]
    @Query private var members: [TripMember]
    @Query private var tripProfiles: [TripProfile]
    @Query private var profiles: [Profile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager

    @State private var toast: String?
    @State private var shareSheetItems: [Any]?
    @State private var isPresentingResetConfirm = false
    @State private var memberPendingRoleChange: TripMember?
    @State private var memberPendingOrganizerConfirm: TripMember?
    @State private var memberPendingRemoval: TripMember?
    @State private var invitePendingRevoke: Invite?
    /// M4: "Add someone without the app" / edit-existing-profile sheets
    /// (this milestone's brief §2) — both drive `TripProfileFormSheet`.
    @State private var isPresentingAddProfile = false
    @State private var editingProfile: TripProfile?

    init(tripId: UUID) {
        self.tripId = tripId
        _trips = Query(filter: #Predicate<Trip> { $0.id == tripId })
        _shareLinks = Query(filter: #Predicate<TripShareLink> { $0.tripId == tripId })
        _invites = Query(filter: #Predicate<Invite> { $0.tripId == tripId })
        _members = Query(filter: #Predicate<TripMember> { $0.tripId == tripId })
        _tripProfiles = Query(filter: #Predicate<TripProfile> { $0.tripId == tripId })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                shareLinkCard
                inviteSection
                peopleSection
            }
            .padding(Spacing.xl)
        }
        .background(Palette.paper)
        .navigationTitle("Share this trip")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay($toast)
        .activityShareSheet(items: $shareSheetItems)
        .sheet(item: $memberPendingRoleChange) { member in
            RolePickerSheet(currentRole: member.role) { newRole in
                memberPendingRoleChange = nil
                if newRole == .organizer {
                    memberPendingOrganizerConfirm = member
                } else {
                    changeRole(of: member, to: newRole)
                }
            } onRemove: {
                memberPendingRoleChange = nil
                memberPendingRemoval = member
            }
        }
        .sheet(isPresented: $isPresentingAddProfile) {
            TripProfileFormSheet(mode: .add) { name, color in
                addProfile(displayName: name, avatarColor: color)
            }
        }
        .sheet(item: $editingProfile) { profile in
            TripProfileFormSheet(
                mode: .edit(profile),
                onSave: { name, color in updateProfile(profile, displayName: name, avatarColor: color) },
                onDelete: { deleteProfile(profile) }
            )
        }
        .confirmationDialog(
            "Reset the share link?",
            isPresented: $isPresentingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset link", role: .destructive) { resetShareLink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone with the old link loses access.")
        }
        .confirmationDialog(
            "Make \(memberPendingOrganizerConfirm.map(displayName) ?? "this person") an organizer?",
            isPresented: Binding(
                get: { memberPendingOrganizerConfirm != nil },
                set: { isPresented in if !isPresented { memberPendingOrganizerConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Make organizer") {
                if let member = memberPendingOrganizerConfirm { changeRole(of: member, to: .organizer) }
                memberPendingOrganizerConfirm = nil
            }
            Button("Cancel", role: .cancel) { memberPendingOrganizerConfirm = nil }
        } message: {
            Text("They\u{2019}ll be able to manage people and delete the trip.")
        }
        .confirmationDialog(
            "Remove \(memberPendingRemoval.map(displayName) ?? "this person") from the trip?",
            isPresented: Binding(
                get: { memberPendingRemoval != nil },
                set: { isPresented in if !isPresented { memberPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let member = memberPendingRemoval { removeMember(member) }
                memberPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { memberPendingRemoval = nil }
        }
        .confirmationDialog(
            "Revoke this invite link?",
            isPresented: Binding(
                get: { invitePendingRevoke != nil },
                set: { isPresented in if !isPresented { invitePendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let invite = invitePendingRevoke { revokeInvite(invite) }
                invitePendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { invitePendingRevoke = nil }
        } message: {
            Text("Anyone who hasn\u{2019}t joined with this link will lose access.")
        }
        .task {
            #if DEBUG
            await applyUITestAutopilotIfNeeded()
            #endif
        }
    }

    // MARK: - Derived

    private var myRole: TripRole? {
        guard let userId = authManager.userId else { return nil }
        return members.first { $0.userId == userId }?.role
    }

    private var isOrganizer: Bool { myRole == .organizer }

    private var activeShareLink: TripShareLink? {
        shareLinks.first { !$0.revoked }
    }

    private var activeInvitesList: [Invite] {
        InvitePermissions.activeInvites(invites.sorted { $0.createdAt > $1.createdAt })
    }

    private var sortedMembers: [TripMember] {
        members.sorted { lhs, rhs in
            if (lhs.role == .organizer) != (rhs.role == .organizer) { return lhs.role == .organizer }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Trip profiles with no linked account yet — the non-app kids/
    /// grandparents (BUILD_PLAN.md §3.3/§5.3). Empty until M4 ships profile
    /// creation; rendered here so the list is ready the moment it does.
    private var unlinkedProfiles: [TripProfile] {
        tripProfiles.filter { $0.linkedUserId == nil }
    }

    private enum PersonRow: Identifiable {
        case member(TripMember)
        case unlinked(TripProfile)

        var id: UUID {
            switch self {
            case .member(let member): member.id
            case .unlinked(let profile): profile.id
            }
        }
    }

    private var personRows: [PersonRow] {
        sortedMembers.map(PersonRow.member) + unlinkedProfiles.map(PersonRow.unlinked)
    }

    private func profile(for member: TripMember) -> TripProfile? {
        tripProfiles.first { $0.linkedUserId == member.userId }
    }

    /// The linked `TripProfile.displayName` is the primary source, but a
    /// pure-offline join (the trip-scoped `TripProfile` a server trigger
    /// creates hasn't synced down yet, though the account-scoped `Profile`
    /// has) falls back to the already-`@Query`'d `profiles` before finally
    /// falling back to "Traveler" — otherwise members read as generic
    /// "Traveler"s until their next successful sync (finding 6).
    private func displayName(for member: TripMember) -> String {
        if let name = profile(for: member)?.displayName { return name }
        if let name = profiles.first(where: { $0.id == member.userId })?.displayName { return name }
        if member.userId == authManager.userId { return "You" }
        return "Traveler"
    }

    private func initials(from displayName: String) -> String {
        let first = displayName.split(separator: " ").first.map(String.init) ?? displayName
        return first.prefix(1).uppercased()
    }

    private func roleBadge(for role: TripRole) -> (icon: String, color: Color, label: String) {
        switch role {
        case .organizer: ("crown.fill", Palette.amber, "Organizer")
        case .companion: ("pencil", CategoryColor.activity.fg, "Companion")
        case .viewer: ("eye.fill", CategoryColor.flight.fg, "Viewer")
        }
    }

    /// Text color for the "Copy"/"Create view link" pills, which sit on
    /// the gradient card and are deliberately always-white (unlike most of
    /// this screen, that pill background doesn't adapt to dark mode) — so
    /// their text must be a fixed dark ink, never the adaptive `Palette.ink`
    /// (which flips near-white in dark mode and would sit unreadably on a
    /// white pill; caught in the M3 dark-mode screenshot pass).
    private static let onWhitePillInk = Color(hex: "#1A1B2E")

    // MARK: - Share link card (top gradient card)

    private var shareLinkCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "link")
                Text("Anyone-can-view link").font(Typo.body(weight: .bold))
            }
            .foregroundStyle(.white)

            Text("Share a read-only itinerary that opens in any browser \u{2014} no app, no account. Perfect for grandparents.")
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            // Non-organizers can never learn whether a link exists — RLS
            // scopes `share_links` SELECT to the organizer too, so their
            // query is always `[]` regardless of the real state
            // (`TripShareLink`'s doc comment). The muted message is
            // therefore unconditional here, not "if none exists".
            if !isOrganizer {
                Text("Only the organizer can create a share link.")
                    .font(Typo.body(Typo.Size.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            } else if let link = activeShareLink {
                shareLinkRow(link)
                Button("Reset link") { isPresentingResetConfirm = true }
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .contentShape(Rectangle())
                    .frame(minHeight: 44)
            } else {
                Button {
                    Task { _ = await createShareLink() }
                } label: {
                    Text("Create view link")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Self.onWhitePillInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                        .background(.white, in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("Booking codes and notes never appear on this link.")
                .font(Typo.body(10.5))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(Spacing.lg)
        .background(CoverGradient.dusk, in: RoundedRectangle(cornerRadius: Radii.card + 4, style: .continuous))
    }

    private func shareLinkRow(_ link: TripShareLink) -> some View {
        let url = DeepLink.shareURL(token: link.token)
        return HStack(spacing: Spacing.sm) {
            Text("\(url.host ?? "")\(url.path)")
                .font(Typo.mono(Typo.Size.caption))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Spacing.sm)

            Button("Copy") { copy(url) }
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Self.onWhitePillInk)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(.white, in: Capsule())
                .contentShape(Rectangle())
                .frame(minWidth: 44, minHeight: 44)

            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.22), in: Circle())
            }
            .accessibilityLabel("Share link")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
    }

    // MARK: - Invite section

    private var inviteSection: some View {
        // Organizer-only, same RLS reality as the share link (`Invite`'s
        // doc comment) — a non-organizer would only ever see `[]` here, so
        // the buttons/rows below are hidden for them, mirroring
        // `shareLinkCard`'s "muted message instead of vanishing" treatment
        // rather than hiding the whole section.
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Invite to edit or view")
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Palette.slate)
                .textCase(.uppercase)

            if isOrganizer {
                HStack(spacing: Spacing.md) {
                    inviteButton(role: .companion, title: "Companion link", icon: "pencil", color: CategoryColor.activity.fg)
                    inviteButton(role: .viewer, title: "Viewer link", icon: "eye.fill", color: CategoryColor.flight.fg)
                }

                Text("Links travel over iMessage, WhatsApp, or however you like to share.")
                    .font(Typo.body(10.5))
                    .foregroundStyle(Palette.slate)

                if !activeInvitesList.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(activeInvitesList.enumerated()), id: \.element.id) { index, invite in
                            inviteRow(invite)
                            if index < activeInvitesList.count - 1 {
                                Rectangle().fill(Palette.mist).frame(height: 1)
                            }
                        }
                    }
                    .padding(.top, Spacing.xs)
                }
            } else {
                Text("Only the organizer can invite people.")
                    .font(Typo.body(Typo.Size.caption, weight: .medium))
                    .foregroundStyle(Palette.slate)
            }
        }
    }

    /// The one active invite of `role`, if any — invites are role-scoped
    /// **reusable** links (`claim_invite`, no single-use field), so tapping
    /// the button again re-shares the existing link instead of minting a
    /// duplicate. Per-recipient/named invites are intentionally NOT built
    /// here (v1.5 scope); one reusable link per role is the correct v1 model.
    private func activeInvite(role: TripRole) -> Invite? {
        InvitePermissions.activeInvite(role: role, in: activeInvitesList)
    }

    private func inviteButton(role: TripRole, title: String, icon: String, color: Color) -> some View {
        let existing = activeInvite(role: role)
        return Button {
            if let existing {
                let url = DeepLink.inviteURL(token: existing.token)
                shareSheetItems = ["Join our trip on Tripto: \(url.absoluteString)"]
            } else {
                Task { _ = await createInvite(role: role) }
            }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: icon)
                    Text(title).font(Typo.body(weight: .semibold))
                }
                Text(existing != nil ? "Share existing link" : role.inviteGrant)
                    .font(Typo.body(10))
                    .opacity(0.85)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func inviteRow(_ invite: Invite) -> some View {
        let info = roleBadge(for: invite.role)
        return HStack(spacing: Spacing.sm) {
            Image(systemName: info.icon)
                .foregroundStyle(info.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(info.label) link")
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Expires \(invite.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
            Spacer(minLength: Spacing.sm)
            Button("Revoke", role: .destructive) { invitePendingRevoke = invite }
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .contentShape(Rectangle())
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - People list

    /// A read-only "what you can do" card so any member — especially a
    /// Companion — can see their own role and its capabilities without needing
    /// the organizer-only role picker (persona dry-run).
    @ViewBuilder
    private var ownRoleCard: some View {
        if let myRole {
            let badge = roleBadge(for: myRole)
            HStack(spacing: Spacing.sm) {
                Image(systemName: badge.icon).foregroundStyle(badge.color).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your role: \(badge.label)")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(myRole.capabilityDescription)
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.md)
            .background(badge.color.opacity(0.08), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ownRoleCard
            Text("On this trip \u{00B7} \(personRows.count)")
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Palette.slate)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(Array(personRows.enumerated()), id: \.element.id) { index, row in
                    Group {
                        switch row {
                        case .member(let member): memberRow(member)
                        case .unlinked(let profile): unlinkedProfileRow(profile)
                        }
                    }
                    if index < personRows.count - 1 {
                        Rectangle().fill(Palette.mist).frame(height: 1)
                    }
                }
            }

            addProfileButton
        }
    }

    /// M4 §2/§5.3: kids, grandparents, anyone assignable with no account.
    /// Same RLS-mirroring gate as adding an itinerary/packing item
    /// (`trip_profiles_insert`: organizer or companion) — reused rather
    /// than reinvented, per `ItemPermissions`'s own doc comment.
    @ViewBuilder
    private var addProfileButton: some View {
        if ItemPermissions.canAdd(role: myRole) {
            Button {
                isPresentingAddProfile = true
            } label: {
                HStack {
                    Image(systemName: "person.badge.plus")
                    Text("Add someone without the app").font(Typo.body(weight: .semibold))
                }
                .foregroundStyle(Palette.indigo)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(Palette.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.sm)
        }
    }

    /// The role pill's visual content, shared between the interactive
    /// (organizer-viewing-someone-else) and inert (everyone else, including
    /// the organizer's own row) presentations — finding 5: `.disabled()`
    /// alone doesn't dim this row's manually-styled `.plain`-button label,
    /// so a non-organizer's pill read as tappable when it never was.
    private func roleBadgeLabel(_ info: (icon: String, color: Color, label: String)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: info.icon).font(.system(size: 11, weight: .semibold))
            Text(info.label).font(Typo.body(Typo.Size.caption, weight: .bold))
        }
        .foregroundStyle(info.color)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(info.color.opacity(0.15), in: Capsule())
    }

    private func memberRow(_ member: TripMember) -> some View {
        let isSelf = member.userId == authManager.userId
        let name = displayName(for: member)
        let colorName = profile(for: member)?.avatarColor ?? profiles.first(where: { $0.id == member.userId })?.avatarColor ?? "slate"
        let info = roleBadge(for: member.role)
        let canManage = MemberRolePermissions.canChangeRole(actingRole: myRole, targetIsSelf: isSelf)
        // Suppresses a redundant "You · you" once `displayName(for:)`'s own
        // offline fallback has already resolved to the "You" placeholder.
        let showsYouSuffix = isSelf && name != "You"

        return HStack(spacing: Spacing.md) {
            Circle()
                .fill(AvatarColor.color(named: colorName))
                .frame(width: 42, height: 42)
                .overlay {
                    Text(initials(from: name)).font(Typo.body(15, weight: .bold)).foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name).font(Typo.body(weight: .semibold)).foregroundStyle(Palette.ink)
                    if showsYouSuffix {
                        Text("\u{00B7} you").font(Typo.body(weight: .medium)).foregroundStyle(Palette.slate)
                    }
                }
                Text(member.role == .organizer ? "created the trip" : "joined")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }

            Spacer(minLength: Spacing.sm)

            if canManage {
                Button {
                    memberPendingRoleChange = member
                } label: {
                    roleBadgeLabel(info)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            } else {
                roleBadgeLabel(info)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    /// Tappable (opens `TripProfileFormSheet` in edit mode) only for
    /// organizers — `trip_profiles_update`/`_delete` RLS is organizer-only
    /// (confirmed live), unlike the insert path `addProfileButton` gates
    /// more permissively. Removal happens from the form sheet's own
    /// "Remove from trip" button, not a swipe action (finding 1:
    /// `.swipeActions` never fires on a `VStack` row inside a `ScrollView`).
    private func unlinkedProfileRow(_ profile: TripProfile) -> some View {
        let content = HStack(spacing: Spacing.md) {
            Circle()
                .fill(AvatarColor.color(named: profile.avatarColor))
                .frame(width: 42, height: 42)
                .overlay {
                    Text(initials(from: profile.displayName)).font(Typo.body(15, weight: .bold)).foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(Typo.body(weight: .semibold)).foregroundStyle(Palette.ink)
                Text("No account yet").font(Typo.body(Typo.Size.caption)).foregroundStyle(Palette.slate)
            }
            Spacer(minLength: Spacing.sm)
            PillLabel(text: "Can be assigned plans \u{00B7} no app needed", tint: .neutral)
            if isOrganizer {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.slate.opacity(0.5))
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())

        return Group {
            if isOrganizer {
                Button { editingProfile = profile } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    // MARK: - Mutations (SYNC_DESIGN.md: SwiftData write on the main
    // context, then `SyncEngine.enqueue` — the same "instant UI, queued
    // sync" flow every mutation in the app uses)... except *creating* a
    // share link or invite, which can't follow that pattern. `token` is
    // `not null unique default encode(gen_random_bytes(16), 'hex')` on both
    // tables (backend schema) — a plain column DEFAULT, only applied when
    // the client omits the column — and is never meant to be client-chosen
    // (backend contract: "INSERTs a row (omit token — DB generates it) then
    // reads it back for the token"). There's no valid optimistic guess for
    // a value only the server assigns, so these two creates go straight to
    // the network and read the real row back in one round trip — the one
    // deliberate exception to this app's otherwise-universal offline-first
    // write path. (Revoking an existing link/invite is a plain field flip
    // with no server-generated value, so that still goes through the
    // normal outbox.)

    private struct CreateShareLinkPayload: Encodable {
        let id: UUID
        let tripId: UUID
        let scope: String
        let revoked: Bool
    }

    private struct CreateInvitePayload: Encodable {
        let id: UUID
        let tripId: UUID
        let role: String
        let createdBy: UUID
        let revoked: Bool
    }

    /// Inserting with the representation requested back (`.select()`
    /// chained onto `.insert()`) makes PostgREST evaluate the table's
    /// SELECT policy against the RETURNING clause *as part of the same
    /// INSERT statement* — confirmed live (curl, bypassing this app
    /// entirely): the identical insert 42501s with `Prefer:
    /// return=representation` and succeeds (201) with `return=minimal`.
    /// `share_links_all`/`invites_all` are single `FOR ALL` policies whose
    /// one `trip_role(trip_id) = 'organizer'` expression backs both the
    /// INSERT's WITH CHECK and (for RETURNING) the SELECT side, and
    /// evaluating both within one statement is the trap — exactly the
    /// class of bug `SyncEngine+Push.swift`'s `pushUpsert` doc comment
    /// already documents for `trips`/`trips_select`, just not previously
    /// hit here because nothing on this screen used `.select()` after an
    /// insert until now. Fix: insert with a minimal return, then read the
    /// row back with a *separate* plain SELECT — its own request, evaluated
    /// once the INSERT (and the trigger-created membership every
    /// `share_links`/`invites` write depends on) has already committed.
    private func insertAndReadBack<Payload: Encodable, Row: Decodable>(
        table: SyncTable,
        id: UUID,
        payload: Payload,
        as _: Row.Type
    ) async throws -> Row {
        try await Supa.client.from(table.rawValue).insert(payload, returning: .minimal).execute()
        return try await Supa.client.from(table.rawValue).select().eq("id", value: id).single().execute().value
    }

    /// A brand-new trip's own `trips` row (and the `trip_members` row a
    /// server trigger creates from it) may not have finished the normal
    /// debounced-outbox round trip yet, so a share link/invite created
    /// moments after the trip itself can transiently 42501 regardless of
    /// the fix above. Retried a few times with a short backoff; a
    /// *persistent* 42501 still surfaces as a failure once exhausted.
    private func withOrganizerRaceRetry<T>(_ attempt: () async throws -> T) async throws -> T {
        var lastError: Error = CancellationError()
        for attemptIndex in 0..<5 {
            do {
                return try await attempt()
            } catch let error as PostgrestError where error.code == "42501" {
                lastError = error
                try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attemptIndex + 1))
            }
        }
        throw lastError
    }

    @discardableResult
    private func createShareLink() async -> TripShareLink? {
        let id = UUID()
        let payload = CreateShareLinkPayload(id: id, tripId: tripId, scope: ShareScope.view.rawValue, revoked: false)
        do {
            let dto: ShareLinkDTO = try await withOrganizerRaceRetry {
                try await insertAndReadBack(table: .shareLinks, id: id, payload: payload, as: ShareLinkDTO.self)
            }
            let link = TripShareLink(dto: dto)
            modelContext.insert(link)
            try? modelContext.save()
            return link
        } catch {
            logDebug("createShareLink failed: \(error)")
            toast = "Couldn\u{2019}t create a share link \u{2014} check your connection."
            return nil
        }
    }

    private func resetShareLink() {
        Task {
            if let existing = activeShareLink {
                existing.revoked = true
                try? modelContext.save()
                let dto = existing.toDTO()
                let id = existing.id
                await syncEngine?.enqueueUpsert(table: .shareLinks, rowId: id, tripId: tripId, payload: dto)
            }
            if await createShareLink() != nil {
                toast = "Link reset"
            }
        }
    }

    private func copy(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        toast = "Link copied"
    }

    /// Creates an invite row of `role`, then (unless `presentShareSheet` is
    /// false — the DEBUG verify-drill autopilot, which can't dismiss a
    /// system share sheet on its own) presents the OS share sheet with the
    /// invite link. Returns the created row so callers that need its token
    /// (the autopilot) don't have to re-query for it.
    @discardableResult
    private func createInvite(role: TripRole, presentShareSheet: Bool = true) async -> Invite? {
        guard let userId = authManager.userId else { return nil }
        let id = UUID()
        let payload = CreateInvitePayload(id: id, tripId: tripId, role: role.rawValue, createdBy: userId, revoked: false)
        do {
            let dto: InviteDTO = try await withOrganizerRaceRetry {
                try await insertAndReadBack(table: .invites, id: id, payload: payload, as: InviteDTO.self)
            }
            let invite = Invite(dto: dto)
            modelContext.insert(invite)
            try? modelContext.save()

            if presentShareSheet {
                let url = DeepLink.inviteURL(token: invite.token)
                shareSheetItems = ["Join our trip on Tripto: \(url.absoluteString)"]
            }
            return invite
        } catch {
            logDebug("createInvite failed: \(error)")
            toast = "Couldn\u{2019}t create an invite link \u{2014} check your connection."
            return nil
        }
    }

    private func revokeInvite(_ invite: Invite) {
        invite.revoked = true
        try? modelContext.save()
        let dto = invite.toDTO()
        let id = invite.id
        Task { await syncEngine?.enqueueUpsert(table: .invites, rowId: id, tripId: tripId, payload: dto) }
        toast = "Invite revoked"
    }

    private func changeRole(of member: TripMember, to newRole: TripRole) {
        guard MemberRolePermissions.canChangeRole(actingRole: myRole, targetIsSelf: member.userId == authManager.userId) else { return }
        member.role = newRole
        try? modelContext.save()
        let dto = member.toDTO()
        let id = member.id
        Task { await syncEngine?.enqueueUpsert(table: .tripMembers, rowId: id, tripId: tripId, payload: dto) }
        toast = "Role updated"
    }

    private func removeMember(_ member: TripMember) {
        let id = member.id
        modelContext.delete(member)
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .tripMembers, rowId: id, tripId: tripId) }
        toast = "Removed from trip"
    }

    // MARK: - Non-app profiles (M4 §2/§5.3)

    private func addProfile(displayName: String, avatarColor: String) {
        guard !displayName.isEmpty else { return }
        let profile = TripProfile(
            id: UUID(), tripId: tripId, displayName: displayName, avatarColor: avatarColor,
            linkedUserId: nil, createdAt: .now
        )
        modelContext.insert(profile)
        try? modelContext.save()
        let dto = profile.toDTO()
        let id = profile.id
        Task { await syncEngine?.enqueueUpsert(table: .tripProfiles, rowId: id, tripId: tripId, payload: dto) }
        toast = "\(displayName) added"
    }

    private func updateProfile(_ profile: TripProfile, displayName: String, avatarColor: String) {
        guard !displayName.isEmpty else { return }
        profile.displayName = displayName
        profile.avatarColor = avatarColor
        try? modelContext.save()
        let dto = profile.toDTO()
        let id = profile.id
        Task { await syncEngine?.enqueueUpsert(table: .tripProfiles, rowId: id, tripId: tripId, payload: dto) }
        toast = "Profile updated"
    }

    private func deleteProfile(_ profile: TripProfile) {
        let id = profile.id
        modelContext.delete(profile)
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .tripProfiles, rowId: id, tripId: tripId) }
        toast = "Removed from trip"
    }

    // MARK: - DEBUG verify-drill autopilot

    #if DEBUG
    /// M3 verify drill: creates a share link and a companion invite (if the
    /// organizer doesn't already have active ones) and writes their tokens
    /// to `UITestBridge`, since there's no GUI tap automation available in
    /// this environment to press the real buttons above.
    private func applyUITestAutopilotIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-uitestSeedShareAndInvite"), isOrganizer else { return }

        // `??`'s right-hand side is an autoclosure that can't itself
        // contain an `await` — spelled as plain `if`s instead.
        var shareToken = activeShareLink?.token
        if shareToken == nil {
            shareToken = await createShareLink()?.token
        }

        var companionToken = activeInvitesList.first { $0.role == .companion }?.token
        if companionToken == nil {
            companionToken = await createInvite(role: .companion, presentShareSheet: false)?.token
        }

        UITestBridge.write([
            "tripId": tripId.uuidString,
            "tripTitle": trips.first?.title ?? "",
            "shareToken": shareToken ?? "",
            "companionInviteToken": companionToken ?? "",
        ])
    }
    #endif
}

/// Role picker for a non-self member row (organizer only — `ShareTripView`
/// gates presenting this sheet at all). Includes Organizer as a selectable
/// option (the M3 brief's "can also promote to Organizer with a confirm"),
/// unlike TripAppFamily.jsx's mockup menu, which only offers Companion/
/// Viewer — the written brief wins per CLAUDE.md.
private struct RolePickerSheet: View {
    let currentRole: TripRole
    let onSelect: (TripRole) -> Void
    /// Finding 1: the only reachable path to removing a member — the old
    /// `.swipeActions` on `memberRow` never fired (attached to a `VStack`
    /// row inside a `ScrollView`, not a `List`). Defaults to `nil` so a
    /// future non-removable presentation of this sheet doesn't have to
    /// thread a callback through just to omit the row.
    var onRemove: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private struct Option {
        let role: TripRole
        let icon: String
        let color: Color
        let description: String
    }

    private let options: [Option] = [
        Option(role: .organizer, icon: "crown.fill", color: Palette.amber, description: TripRole.organizer.capabilityDescription),
        Option(role: .companion, icon: "pencil", color: CategoryColor.activity.fg, description: TripRole.companion.capabilityDescription),
        Option(role: .viewer, icon: "eye.fill", color: CategoryColor.flight.fg, description: TripRole.viewer.capabilityDescription),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(options, id: \.role) { option in
                    Button {
                        dismiss()
                        onSelect(option.role)
                    } label: {
                        HStack(spacing: Spacing.md) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(option.color.opacity(0.15))
                                .frame(width: 34, height: 34)
                                .overlay { Image(systemName: option.icon).foregroundStyle(option.color) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.role.rawValue.capitalized)
                                    .font(Typo.body(weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                Text(option.description)
                                    .font(Typo.body(Typo.Size.caption))
                                    .foregroundStyle(Palette.slate)
                            }
                            Spacer(minLength: 0)
                            if option.role == currentRole {
                                Image(systemName: "checkmark").foregroundStyle(Palette.amber)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let onRemove {
                    Button(role: .destructive) {
                        dismiss()
                        onRemove()
                    } label: {
                        Text("Remove from trip")
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Change role")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
