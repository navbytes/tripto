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
    /// Bug fix: the card used to only offer "Reset link" (revoke +
    /// immediately create a replacement) — no way to just turn the link
    /// off. Mirrors `invitePendingRevoke`'s "revoke, no replacement"
    /// pattern below. P4.1 (docs/UX_REDESIGN_ROADMAP.md): now also the
    /// confirm gate behind the compact public-link row's own Toggle turning
    /// off — see `publicLinkToggleBinding`.
    @State private var linkPendingRemoval: TripShareLink?
    @State private var memberPendingOrganizerConfirm: TripMember?
    @State private var memberPendingRemoval: TripMember?
    /// P4.1: the Traveller chip menu's "Remove from trip" — same shape as
    /// `memberPendingRemoval` above, for the no-account `TripProfile` rows.
    @State private var profilePendingRemoval: TripProfile?
    @State private var invitePendingRevoke: Invite?
    /// Guards the deliberate network-bound share-link create (see the
    /// "Mutations" doc comment below) — without this, a double-tap on the
    /// public-link row's Toggle fires two concurrent inserts. Kept in the
    /// Toggle's own binding, not inside `createShareLink()`, so the DEBUG
    /// autopilot isn't blocked by a reentrancy guard.
    @State private var busyShareLink = false
    /// Same as `busyShareLink`, per-role, for the two invite buttons.
    @State private var busyInviteRoles: Set<TripRole> = []
    /// M4: "Add someone without the app" / edit-existing-profile sheets
    /// (this milestone's brief §2) — both drive `TripProfileFormSheet`.
    @State private var isPresentingAddProfile = false
    @State private var editingProfile: TripProfile?
    /// Scope amendment to P4.2 (docs/UX_REDESIGN_ROADMAP.md, mid-build):
    /// the full `ImportAddressCard` cluster moved to `AddItemSheet`, but
    /// the client still reaches for the trip's email-import address from
    /// Share by muscle memory — `forwardBookingEmailsRow` keeps it findable
    /// here, one tap deeper, via this sheet. Same card/consent flow as
    /// before (and as `AddItemSheet`'s own copy) — no second copy of the
    /// disclosure.
    @State private var isPresentingImportAddress = false
    /// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): this trip's real import address,
    /// fetched once per screen visit and cached here — mirrors
    /// `AddItemSheet`/`ItineraryTabView`'s own identically-shaped pair.
    /// A5 (`docs/BACKLOG.md`): starts `.needsConsent` (not `.loading`) when
    /// consent isn't on record yet, same reasoning as those two.
    @State private var importLoadState: ImportAddressCard.LoadState = EmailImportConsent.isGranted() ? .loading : .needsConsent
    @State private var hasFetchedImportAddress = false
    /// P6.3 (docs/UX_REDESIGN_ROADMAP.md): the traveller-dedupe banner's
    /// "Review" destination.
    @State private var isPresentingDedupeReview = false

    /// `shareLinkRow`'s `ShareLink` icon — glyph+container scaled together
    /// (this view owns the whole row, no external layout contract on its
    /// 30pt circle, unlike `Fab`/`GlassCircleButton`).
    @ScaledMetric(relativeTo: .caption) private var shareIconFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var shareIconDiameter: CGFloat = 30
    /// Small caption-adjacent glyphs: `roleBadgeLabel`'s icon and
    /// `unlinkedProfileRow`'s disclosure chevron, both originally 11pt.
    @ScaledMetric(relativeTo: .caption) private var captionIconSize: CGFloat = 11

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
            // P4.1 (docs/UX_REDESIGN_ROADMAP.md): people first — "who's on
            // this trip and what can they do" is the screen's job, a link is
            // the mechanism, not the feature. Invite is the primary action
            // right under the list; the public link (the least-common path)
            // is demoted to a compact row at the bottom. The full "paste OR
            // forward" email-import cluster moved to `AddItemSheet` (P4.2)
            // — `forwardBookingEmailsRow` keeps the address findable here
            // too, one tap deeper (scope amendment), in the same
            // demoted/utility area as the public link.
            VStack(alignment: .leading, spacing: Spacing.xl) {
                peopleSection
                dedupeBanner
                inviteSection
                publicLinkSection
                forwardBookingEmailsRow
            }
            .padding(Spacing.xl)
        }
        .background(Palette.paper)
        .navigationTitle("Share this trip")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay($toast)
        .activityShareSheet(items: $shareSheetItems)
        // Scope amendment to P4.2: `forwardBookingEmailsRow`'s "one tap
        // deeper" — the exact same `ImportAddressCard` component/consent
        // flow `AddItemSheet.importAddressCard` wires up, just presented in
        // its own small sheet here instead of inline in a form.
        .sheet(isPresented: $isPresentingImportAddress) {
            NavigationStack {
                VStack(spacing: 0) {
                    SheetHeader(title: "Forward booking emails", onCancel: { isPresentingImportAddress = false })
                    ScrollView {
                        ImportAddressCard(state: importLoadState) { address in
                            toast = ClipboardFeedback.copy(address, label: "Import address")
                        } onRetry: {
                            retryImportAddressFetch()
                        } onConsentGranted: {
                            grantEmailImportConsentAndFetch()
                        }
                        .padding(Spacing.xl)
                    }
                }
                .background(Palette.paper)
                .toolbar(.hidden, for: .navigationBar)
            }
            .presentationDetents([.medium])
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
        // P6.3 (docs/UX_REDESIGN_ROADMAP.md): the dedupe banner's "Review"
        // destination.
        .sheet(isPresented: $isPresentingDedupeReview) {
            ProfileDedupeReviewSheet(pairs: duplicateProfilePairs) { survivor, duplicate in
                Task { await mergeDuplicateProfiles(survivor: survivor, duplicate: duplicate) }
            }
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
        // P4.1: the Traveller chip menu's "Remove from trip" — same copy
        // `TripProfileFormSheet`'s own internal confirm already uses, just a
        // second reachable entry point now that removal is also offered
        // inline instead of only from inside the edit sheet.
        .confirmationDialog(
            "Remove \(profilePendingRemoval?.displayName ?? "this person") from the trip?",
            isPresented: Binding(
                get: { profilePendingRemoval != nil },
                set: { isPresented in if !isPresented { profilePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let profile = profilePendingRemoval { deleteProfile(profile) }
                profilePendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { profilePendingRemoval = nil }
        } message: {
            Text("They\u{2019}ll no longer be assignable on plans or packing tasks.")
        }
        .confirmationDialog(
            "Remove the share link?",
            isPresented: Binding(
                get: { linkPendingRemoval != nil },
                set: { isPresented in if !isPresented { linkPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove link", role: .destructive) {
                if let link = linkPendingRemoval { removeShareLink(link) }
                linkPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { linkPendingRemoval = nil }
        } message: {
            Text("Anyone with this link loses access. You can create a new one anytime.")
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
        // `myRole` is `@Query`-derived and can still be empty on first
        // render (fresh install, just-joined trip, this screen opened
        // before member sync completes) — re-running on every `myRole`
        // change (rather than a plain one-shot `.task`) is what lets a
        // later sync-in retry the one real fetch attempt
        // `fetchImportAddressIfNeeded()`'s own guard only allows once.
        .task(id: myRole) { await fetchImportAddressIfNeeded() }
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

    /// The trip's actual creator — the earliest-joined `TripMember` (a
    /// server trigger creates the organizer's `trip_members` row at trip
    /// creation, before anyone else can join). `memberRow`'s caption used to
    /// read `role == .organizer` as "created the trip", which goes stale the
    /// moment a co-organizer is promoted (finding 4) — this instead derives
    /// the one true creator, using the same `createdAt` field `sortedMembers`
    /// already relies on.
    private var tripCreatorId: UUID? {
        members.min(by: { $0.createdAt < $1.createdAt })?.userId
    }

    /// Trip profiles with no linked account yet — the non-app kids/
    /// grandparents (BUILD_PLAN.md §3.3/§5.3). Empty until M4 ships profile
    /// creation; rendered here so the list is ready the moment it does.
    private var unlinkedProfiles: [TripProfile] {
        tripProfiles.filter { $0.linkedUserId == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    /// P6.3 (docs/UX_REDESIGN_ROADMAP.md): within-this-trip traveller
    /// duplicates — `tripProfiles` is already trip-scoped by this view's
    /// own `@Query` filter (`init` above), so there is nothing cross-trip
    /// this can ever see (that identity problem is explicitly fenced,
    /// docs/BACKLOG.md). Not gated on "was this just imported" — a general,
    /// always-on detection over whatever profiles exist on the trip right
    /// now is simpler than tracking a one-shot post-import flag, and
    /// correctly also catches a manually-added duplicate (e.g. "Mom" added
    /// twice by accident), not just an import-created one.
    private var duplicateProfilePairs: [ProfileDedupe.Pair] {
        ProfileDedupe.duplicatePairs(in: tripProfiles)
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

    // MARK: - Public link (compact switch row — P4.1, demoted + last)

    /// P4.1 (docs/UX_REDESIGN_ROADMAP.md): demoted from the top gradient
    /// hero card to a compact switch-style row, moved last — inviting people
    /// you know is the common case, so the public link no longer has to be
    /// the loudest thing on the screen. The `Toggle` IS the create/revoke
    /// control now: turning it on calls `createShareLink()`, turning it off
    /// routes through the exact same confirmation `linkPendingRemoval`
    /// already gated (`removeShareLink()`) rather than revoking instantly —
    /// see `publicLinkToggleBinding`. The old one-tap "Reset link" (revoke +
    /// immediately replace) doesn't carry over to a two-state switch; the
    /// same end result is still one toggle-off, toggle-on away.
    private var publicLinkSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Public page")
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Palette.slate)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "link")
                        .foregroundStyle(Palette.slate)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Anyone-can-view link")
                            .font(Typo.body(weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            // Fix-round N2: this exact string is also the
                            // Toggle's own (visually `.labelsHidden()`, but
                            // still spoken) accessibility label right below
                            // — VoiceOver read it twice on this row. The
                            // subtitle underneath is unique content, kept.
                            .accessibilityHidden(true)
                        Text("Opens in any browser \u{2014} no app, no account.")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(Palette.slate)
                    }
                    Spacer(minLength: Spacing.sm)
                    // Non-organizers can never learn whether a link exists —
                    // RLS scopes `share_links` SELECT to the organizer too,
                    // so their query is always `[]` regardless of the real
                    // state (`TripShareLink`'s doc comment) — the switch
                    // itself is therefore organizer-only, not just disabled.
                    if isOrganizer {
                        Toggle("Anyone-can-view link", isOn: publicLinkToggleBinding)
                            .labelsHidden()
                            .tint(Palette.amber)
                            .disabled(busyShareLink)
                    }
                }

                if !isOrganizer {
                    Text("Only the organizer can create a share link.")
                        .font(Typo.body(Typo.Size.caption, weight: .medium))
                        .foregroundStyle(Palette.slate)
                } else if busyShareLink {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                        Text("Updating link\u{2026}")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(Palette.slate)
                    }
                } else if let link = activeShareLink {
                    shareLinkRow(link)
                }

                Text("Booking codes and notes never appear on this link.")
                    .font(Typo.body(10.5))
                    .foregroundStyle(Palette.slate)
            }
            .padding(Spacing.md)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .stroke(Palette.mist, lineWidth: 1)
            }
        }
    }

    /// The switch's create/revoke bridge — derives `isOn` from
    /// `activeShareLink` (the real `@Query`-backed source of truth) rather
    /// than owning a separate boolean, so cancelling the revoke confirm
    /// dialog needs no manual "snap back": `activeShareLink` never actually
    /// changed, so `get` just re-derives `true` on the next render. Same
    /// derived-`Binding` idiom `SettingsView`'s archive-alert bindings
    /// already use.
    private var publicLinkToggleBinding: Binding<Bool> {
        Binding(
            get: { activeShareLink != nil || busyShareLink },
            set: { isOn in
                if isOn {
                    guard activeShareLink == nil, !busyShareLink else { return }
                    Task {
                        busyShareLink = true
                        _ = await createShareLink()
                        busyShareLink = false
                    }
                } else if let link = activeShareLink {
                    linkPendingRemoval = link
                }
            }
        )
    }

    private func shareLinkRow(_ link: TripShareLink) -> some View {
        let url = DeepLink.shareURL(token: link.token)
        return HStack(spacing: Spacing.sm) {
            Text("\(url.host ?? "")\(url.path)")
                .font(Typo.mono(Typo.Size.caption))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Spacing.sm)

            Button("Copy") { copy(url) }
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .overlay {
                    Capsule().stroke(Palette.mist, lineWidth: 1)
                }
                .contentShape(Rectangle())
                .frame(minWidth: 44, minHeight: 44)
                // States the action rather than the bare "Copy" (finding:
                // out of context — e.g. right after a page's Edit/Copy —
                // the label alone doesn't say what's being copied).
                .accessibilityLabel("Copy link")

            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: shareIconFontSize, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    .frame(width: shareIconDiameter, height: shareIconDiameter)
                    .contentShape(Rectangle())
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Share link")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
    }

    // MARK: - Forward booking emails (compact pointer — P4.2 scope amendment)

    /// Scope amendment to P4.2 (docs/UX_REDESIGN_ROADMAP.md, mid-build):
    /// the full "paste OR forward" cluster moved to `AddItemSheet`, but the
    /// client reaches for the email-import address from Share by muscle
    /// memory — this compact row keeps it findable here too, one tap
    /// deeper (`isPresentingImportAddress`'s sheet in `body`). Same
    /// `ItemPermissions.canAdd` gate `importCard` used before this
    /// amendment; same reasoning as `AddItemSheet.importAddressCard` for
    /// why: the underlying RPC needs trip membership, so a viewer/signed-out
    /// visitor would just fail/spin for a row they can never see anyway.
    @ViewBuilder
    private var forwardBookingEmailsRow: some View {
        if ItemPermissions.canAdd(role: myRole) {
            Button {
                isPresentingImportAddress = true
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "envelope.badge")
                        .foregroundStyle(Palette.slate)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text("Forward booking emails")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: Spacing.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: captionIconSize, weight: .semibold))
                        .foregroundStyle(Palette.slate.opacity(0.5))
                        .accessibilityHidden(true)
                }
                .padding(Spacing.md)
                .frame(minHeight: 44)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                        .stroke(Palette.mist, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens your trip's email-import address")
        }
    }

    /// Same one-shot-per-visit shape as `AddItemSheet.fetchImportAddressIfNeeded()`
    /// (identical reasoning — `myRole` resolves asynchronously via `@Query`,
    /// so `.task(id: myRole)` above re-invokes this on every change rather
    /// than firing once).
    private func fetchImportAddressIfNeeded() async {
        guard ItemPermissions.canAdd(role: myRole), !hasFetchedImportAddress else { return }
        guard EmailImportConsent.fetchDecision() == .fetchImmediately else { return }
        hasFetchedImportAddress = true
        await fetchImportAddress()
    }

    /// The actual RPC call, split out so `retryImportAddressFetch()` can
    /// re-run it without re-triggering `hasFetchedImportAddress`'s guard.
    private func fetchImportAddress() async {
        do {
            importLoadState = .loaded(try await TripImportAddress.fetch(tripId: tripId))
        } catch {
            importLoadState = .failed
        }
    }

    private func retryImportAddressFetch() {
        importLoadState = .loading
        Task { await fetchImportAddress() }
    }

    private func grantEmailImportConsentAndFetch() {
        EmailImportConsent.grant()
        hasFetchedImportAddress = true
        retryImportAddressFetch()
    }

    // MARK: - Invite section

    private var inviteSection: some View {
        // Organizer-only, same RLS reality as the share link (`Invite`'s
        // doc comment) — a non-organizer would only ever see `[]` here, so
        // the buttons/rows below are hidden for them, mirroring
        // `publicLinkSection`'s "muted message instead of vanishing"
        // treatment rather than hiding the whole section.
        VStack(alignment: .leading, spacing: Spacing.md) {
            // P4.1: positioned as the primary action right under the people
            // list now (was "Invite to edit or view", second on the screen
            // behind the old gradient link hero) — same two role-scoped
            // invite links/logic below, unchanged.
            Text("Invite someone")
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
        let isBusy = busyInviteRoles.contains(role)
        return Button {
            if let existing {
                let url = DeepLink.inviteURL(token: existing.token)
                shareSheetItems = ["Join our trip on Tripto: \(url.absoluteString)"]
            } else {
                Task {
                    busyInviteRoles.insert(role)
                    _ = await createInvite(role: role)
                    busyInviteRoles.remove(role)
                }
            }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isBusy ? "hourglass" : icon)
                        .accessibilityHidden(true)
                    Text(title).font(Typo.body(weight: .semibold))
                }
                if isBusy {
                    HStack(spacing: 4) {
                        ProgressView().tint(color).scaleEffect(0.7)
                        Text("Creating\u{2026}").font(Typo.body(10)).opacity(0.85)
                    }
                } else {
                    Text(existing != nil ? "Share existing link" : role.inviteGrant)
                        .font(Typo.body(10))
                        .opacity(0.85)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func inviteRow(_ invite: Invite) -> some View {
        let info = roleBadge(for: invite.role)
        return HStack(spacing: Spacing.sm) {
            Image(systemName: info.icon)
                .foregroundStyle(info.color)
                .frame(width: 22)
                .accessibilityHidden(true)
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

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
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
            whoCanDoWhatDisclosure
        }
    }

    /// P6.3 (docs/UX_REDESIGN_ROADMAP.md): a quiet, organizer-only heads-up
    /// — mirrors `ItineraryTabView.conflictBanner`'s exact "amber-wash
    /// notice + a compact ink-filled pill action" recipe (P2.1), the
    /// closest existing precedent in this app for "detected a probably-
    /// accidental duplicate, offer a review." Organizer-only: merging
    /// re-points `item_assignees`/`packing_items` and deletes a
    /// `trip_profiles` row, which is organizer-only RLS
    /// (`unlinkedProfileRow`'s own doc comment: "confirmed live") — showing
    /// an action neither other role could complete would be a dead end.
    @ViewBuilder
    private var dedupeBanner: some View {
        if isOrganizer, !duplicateProfilePairs.isEmpty {
            let count = duplicateProfilePairs.count
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "person.2.badge.gearshape")
                        .foregroundStyle(Palette.amberInk)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    Text(count == 1
                        ? "1 name looks like the same person \u{2014} Review"
                        : "\(count) names look like the same person \u{2014} Review")
                        .font(Typo.body(weight: .bold))
                        .foregroundStyle(Palette.ink)
                }
                .accessibilityElement(children: .combine)

                Button("Review") { isPresentingDedupeReview = true }
                    .font(Typo.body(13, weight: .semibold))
                    .foregroundStyle(Palette.paper)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Palette.ink, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                    .buttonStyle(.plain)
            }
            .padding(Spacing.md)
            // Same already-audited pairing `ImportResultSheet`/
            // `ItineraryTabView.conflictBanner` reuse: `Palette.ink` on
            // `Palette.amberSoft` ~14.4:1 light / ~10.9:1 dark; `Palette
            // .paper` on `Palette.ink` (the button) ~16.2:1 / ~16.1:1.
            .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
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

    /// Fix-round D1: deleting `ownRoleCard` removed the only place
    /// explaining what each role/chip actually does. Restored the mockup's
    /// own way (Share phone note 3 / "The role model" table in
    /// design/ux-redesign-2026-07/tripto-redesign-dark.html) — a collapsed-
    /// by-default disclosure at the bottom of the people list, not a
    /// standing card. Static copy (not `TripRole.capabilityDescription`,
    /// which `ownRoleCard` read): this also needs a Traveller line, which
    /// isn't a `TripRole` case. Icons/colors reuse `roleBadge`/`travellerBadge`
    /// so the chips and this legend never disagree on either.
    private var whoCanDoWhatDisclosure: some View {
        DisclosureGroup("Who can do what") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                whoCanDoWhatRow(roleBadge(for: .organizer), capability: "Everything, incl. people & delete")
                whoCanDoWhatRow(roleBadge(for: .companion), capability: "Add & edit their own plans")
                whoCanDoWhatRow(roleBadge(for: .viewer), capability: "Read")
                whoCanDoWhatRow(travellerBadge, capability: "Can be assigned plans, no account needed")
            }
            .padding(.top, Spacing.sm)
        }
        .font(Typo.body(weight: .semibold))
        .foregroundStyle(Palette.ink)
        .tint(Palette.slate)
        .padding(.top, Spacing.sm)
    }

    /// One line per role — icon + role name + its one-line capability,
    /// combined into a single VoiceOver stop ("Organizer. Everything,
    /// including people and delete.") rather than two separate ones.
    private func whoCanDoWhatRow(_ info: (icon: String, color: Color, label: String), capability: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: info.icon)
                .foregroundStyle(info.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.label).font(Typo.body(weight: .semibold)).foregroundStyle(Palette.ink)
                Text(capability).font(Typo.body(Typo.Size.caption)).foregroundStyle(Palette.slate)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The role pill's visual content, shared between the interactive
    /// (organizer-viewing-someone-else) and inert (everyone else, including
    /// the organizer's own row) presentations — finding 5: `.disabled()`
    /// alone doesn't dim this row's manually-styled `.plain`-button label,
    /// so a non-organizer's pill read as tappable when it never was.
    private func roleBadgeLabel(_ info: (icon: String, color: Color, label: String)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: info.icon)
                .font(.system(size: captionIconSize, weight: .semibold))
                .accessibilityHidden(true)
            // Fix-round N3: "Traveller" wrapped mid-word ("Travell/er") at
            // AX3 — the row's `Spacer` was squeezing this below its own
            // single-line width. Same `.fixedSize()` idiom `SheetHeader`'s
            // "Cancel" button already uses for the identical squeeze; a
            // no-op at default sizes (natural width already fits), and it
            // fixes every role chip uniformly, not just Traveller's.
            Text(info.label)
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .fixedSize()
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
                // Decorative — the name `Text` right after already carries
                // this identity.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name).font(Typo.body(weight: .semibold)).foregroundStyle(Palette.ink)
                    if showsYouSuffix {
                        Text("\u{00B7} you").font(Typo.body(weight: .medium)).foregroundStyle(Palette.slate)
                    }
                }
                Text(member.userId == tripCreatorId ? "created the trip" : "joined")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }

            Spacer(minLength: Spacing.sm)

            if canManage {
                // P4.1 (docs/UX_REDESIGN_ROADMAP.md): replaces the separate
                // `RolePickerSheet` — the chip itself is now the picker via
                // an inline `Menu`. `Picker` + `.pickerStyle(.inline)` nested
                // directly inside `Menu` content is the standard SwiftUI
                // idiom for a checkmarked in-menu picker (no separate sheet,
                // Dynamic Type/VoiceOver/44pt all still system-provided).
                Menu {
                    Picker("Role", selection: rolePickerBinding(for: member)) {
                        ForEach(TripRole.allCases, id: \.self) { role in
                            Label(role.rawValue.capitalized, systemImage: roleBadge(for: role).icon).tag(role)
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        memberPendingRemoval = member
                    } label: {
                        Label("Remove from trip", systemImage: "person.badge.minus")
                    }
                } label: {
                    roleBadgeLabel(info)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                }
                // Role chip menu: states the current role and that tapping
                // changes it, rather than the badge's icon/text alone.
                .accessibilityLabel("Role: \(info.label)")
                .accessibilityHint("Changes role")
            } else {
                roleBadgeLabel(info)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    /// P4.1: the same role-scoped destination `RolePickerSheet.onSelect`
    /// used to resolve — organizer needs the extra promote confirmation,
    /// everyone else changes immediately — factored into a pure
    /// `roleMenuAction(selected:current:)` below so
    /// `ShareTripViewRoleMenuTests` can pin the mapping without a live
    /// `Menu`/`ModelContext`. The `Picker`'s own selection binding just
    /// dispatches on that pure result.
    private func rolePickerBinding(for member: TripMember) -> Binding<TripRole> {
        Binding(
            get: { member.role },
            set: { newRole in
                switch Self.roleMenuAction(selected: newRole, current: member.role) {
                case .none:
                    break
                case .confirmPromoteToOrganizer:
                    memberPendingOrganizerConfirm = member
                case .changeRoleImmediately(let role):
                    changeRole(of: member, to: role)
                }
            }
        )
    }

    /// The inline role-chip `Menu`'s tap-to-select outcome. Picking the role
    /// a member already has is a no-op (the underlying value didn't change,
    /// nothing to write); picking Organizer routes through the same promote
    /// confirmation dialog `RolePickerSheet` used to gate before this inline
    /// menu replaced it; anything else changes the role immediately.
    enum RoleMenuAction: Equatable {
        case none
        case confirmPromoteToOrganizer
        case changeRoleImmediately(TripRole)
    }

    static func roleMenuAction(selected: TripRole, current: TripRole) -> RoleMenuAction {
        guard selected != current else { return .none }
        if selected == .organizer { return .confirmPromoteToOrganizer }
        return .changeRoleImmediately(selected)
    }

    /// P4.1: the no-account `TripProfile`'s badge tuple, same shape as
    /// `roleBadge(for:)` (reused via the same `roleBadgeLabel` renderer) but
    /// not a `TripRole` case — a traveller has no role, no access, no app
    /// (BUILD_PLAN §3.3/§5.3). `Palette.ink`, not one of the three role
    /// hues: measured ~11.96:1 light / ~10.63:1 dark against this label's
    /// own `.opacity(0.15)` capsule fill (`roleBadgeLabel`'s background),
    /// comfortably clearing WCAG AA — `Palette.slate` in the same spot
    /// measured only ~4.25:1 light, under the 4.5:1 bar for this caption-
    /// bold text.
    private var travellerBadge: (icon: String, color: Color, label: String) {
        (icon: "person.fill", color: Palette.ink, label: "Traveller")
    }

    /// Tappable (organizer only — `trip_profiles_update`/`_delete` RLS is
    /// organizer-only, confirmed live) via the same chip-`Menu` control
    /// style as `memberRow`'s role chip (P4.1) — offers exactly the two
    /// actions this profile already had (`TripProfileFormSheet`'s own Edit
    /// fields + its "Remove from trip" button), just reachable inline now
    /// instead of only after opening the sheet. No new capability.
    private func unlinkedProfileRow(_ profile: TripProfile) -> some View {
        HStack(spacing: Spacing.md) {
            Circle()
                .fill(AvatarColor.color(named: profile.avatarColor))
                .frame(width: 42, height: 42)
                .overlay {
                    Text(initials(from: profile.displayName)).font(Typo.body(15, weight: .bold)).foregroundStyle(.white)
                }
                // Decorative — the name `Text` right after already carries
                // this identity.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(Typo.body(weight: .semibold)).foregroundStyle(Palette.ink)
                Text("No account yet").font(Typo.body(Typo.Size.caption)).foregroundStyle(Palette.slate)
            }
            Spacer(minLength: Spacing.sm)

            if isOrganizer {
                Menu {
                    Button {
                        editingProfile = profile
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        profilePendingRemoval = profile
                    } label: {
                        Label("Remove from trip", systemImage: "person.badge.minus")
                    }
                } label: {
                    roleBadgeLabel(travellerBadge)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Role: Traveller")
                .accessibilityHint("Opens edit and remove options")
            } else {
                roleBadgeLabel(travellerBadge)
            }
        }
        .padding(.vertical, Spacing.sm)
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
            if let pg = error as? PostgrestError, pg.code == "42501" {
                toast = "Couldn\u{2019}t create the link yet \u{2014} this trip is still syncing. Try again in a moment."
            } else {
                toast = "Couldn\u{2019}t create a share link \u{2014} check your connection."
            }
            return nil
        }
    }

    /// P4.1 (docs/UX_REDESIGN_ROADMAP.md): the public-link switch's
    /// toggle-off path, via `publicLinkToggleBinding` -> `linkPendingRemoval`
    /// -> this confirmed revoke. Same local-write-then-enqueue shape as
    /// `revokeInvite`; no `busyShareLink` guard needed since (unlike create)
    /// this never makes a network round trip itself before the local write.
    /// The old one-tap "Reset link" (revoke + immediately replace) doesn't
    /// carry over to the two-state switch — toggling off then back on
    /// reaches the same end state.
    private func removeShareLink(_ link: TripShareLink) {
        link.revoked = true
        try? modelContext.save()
        let dto = link.toDTO()
        let id = link.id
        Task { await syncEngine?.enqueueUpsert(table: .shareLinks, rowId: id, tripId: tripId, payload: dto) }
        toast = "Link removed"
    }

    // UX audit finding 6: routes through the same `ClipboardFeedback` helper
    // `BookingDetailView`'s code/ticket copy now uses, so both screens'
    // tap-to-copy affordances share one haptic+toast pattern.
    private func copy(_ url: URL) {
        toast = ClipboardFeedback.copy(url.absoluteString, label: "Link")
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
            if let pg = error as? PostgrestError, pg.code == "42501" {
                toast = "Couldn\u{2019}t create the link yet \u{2014} this trip is still syncing. Try again in a moment."
            } else {
                toast = "Couldn\u{2019}t create an invite link \u{2014} check your connection."
            }
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

    /// P6.3 (docs/UX_REDESIGN_ROADMAP.md): the dedupe review sheet's
    /// confirmed "Merge". `ProfileDedupe.merge` does the SwiftData work
    /// (re-point `item_assignees`/packing, delete `duplicate`'s
    /// `trip_profiles` row); this method supplies the context, the pull
    /// closure, and the outbox enqueue — same split every merge/dedupe
    /// helper in this phase uses (`TripMerge`/`HomeView.performMerge`).
    /// The final `trip_profiles` delete mirrors `deleteProfile` above's
    /// exact enqueue shape — no new server call shape, just driven from
    /// here instead of that method directly (this is a different row: the
    /// DUPLICATE, not necessarily one the user tapped "Remove" on).
    @MainActor
    private func mergeDuplicateProfiles(survivor: TripProfile, duplicate: TripProfile) async {
        let survivorId = survivor.id
        let duplicateId = duplicate.id
        guard let result = await ProfileDedupe.merge(
            survivorId: survivorId, duplicateId: duplicateId, tripId: tripId, modelContext: modelContext,
            // Same trip-scoped-mirror rule as `TripMerge`/`HomeDuplication`
            // — `item_assignees` (like itinerary items/packing) enters the
            // local mirror only via `pullTrip`. `TripView`'s own `onAppear`
            // already schedules this for the CURRENTLY open trip, but this
            // screen is only ever reached from inside one, so a defensive
            // direct pull costs nothing and removes any doubt.
            ensureTripLoaded: { await syncEngine?.pullTrip(tripId) }
        ) else {
            toast = "Couldn\u{2019}t merge \u{2014} try again."
            return
        }

        for itemId in result.itemIdsToUnassignFromDuplicate {
            await syncEngine?.enqueueDeleteItemAssignee(itemId: itemId, profileId: duplicateId, tripId: tripId)
        }
        for itemId in result.itemIdsToAssignToSurvivor {
            await syncEngine?.enqueueUpsert(
                table: .itemAssignees, rowId: ItemAssignee.compositeId(itemId: itemId, profileId: survivorId),
                tripId: tripId, payload: ItemAssigneeDTO(itemId: itemId, profileId: survivorId)
            )
        }
        for packingItem in result.repointedPackingItems {
            await syncEngine?.enqueueUpsert(table: .packingItems, rowId: packingItem.id, tripId: tripId, payload: packingItem.toDTO())
        }
        await syncEngine?.enqueueDelete(table: .tripProfiles, rowId: duplicateId, tripId: tripId)
        toast = "Merged into \(survivor.displayName)"
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
            "companionInviteToken": companionToken ?? ""
        ])
    }
    #endif
}

// Fix-round D2: `RolePickerSheet` (the pre-P4.1 role-change sheet) deleted —
// zero call sites since the inline chip `Menu` (`memberRow`) replaced it.

/// P6.3 (docs/UX_REDESIGN_ROADMAP.md): `dedupeBanner`'s "Review" destination
/// — one row per detected pair, Merge (confirm-gated here — this
/// permanently deletes a `trip_profiles` row, same "destructive ops MUST be
/// confirm-gated" contract every other delete on this screen already
/// follows) or Keep both. "Keep both" only dismisses the pair for this
/// sheet visit (`dismissedIds`, local `@State`) — nothing persists, so an
/// unmerged pair resurfaces the next time this sheet opens, same as
/// `ItineraryTabView`'s own conflict banner staying up until the
/// underlying data actually changes.
private struct ProfileDedupeReviewSheet: View {
    let pairs: [ProfileDedupe.Pair]
    let onMerge: (TripProfile, TripProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dismissedIds: Set<UUID> = []
    @State private var pairPendingConfirm: ProfileDedupe.Pair?

    /// Same `AnyLayout` swap `DuplicateTripStrip`/`TripCard.topLayout`
    /// already use — a label plus two buttons has no room to sit side by
    /// side at accessibility Dynamic Type sizes.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(spacing: Spacing.md))
    }

    private var visiblePairs: [ProfileDedupe.Pair] {
        pairs.filter { !dismissedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if visiblePairs.isEmpty {
                    Text("Nothing left to review.")
                        .foregroundStyle(Palette.slate)
                } else {
                    ForEach(visiblePairs) { pair in
                        row(pair)
                    }
                }
            }
            .navigationTitle("Possible duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Merge these two?",
            isPresented: Binding(
                get: { pairPendingConfirm != nil },
                set: { isPresented in if !isPresented { pairPendingConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                if let pair = pairPendingConfirm { onMerge(pair.survivor, pair.duplicate) }
                pairPendingConfirm = nil
            }
            Button("Cancel", role: .cancel) { pairPendingConfirm = nil }
        } message: {
            if let pair = pairPendingConfirm {
                Text(
                    "\u{201C}\(pair.duplicate.displayName)\u{201D} will be removed \u{2014} their plans and packing "
                        + "tasks move to \u{201C}\(pair.survivor.displayName)\u{201D}. This can\u{2019}t be undone."
                )
            }
        }
    }

    private func row(_ pair: ProfileDedupe.Pair) -> some View {
        rowLayout {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pair.survivor.displayName) & \(pair.duplicate.displayName)")
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Same name")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
            // One VoiceOver stop for the label pair; both buttons stay
            // their own, separately reachable controls (same "combine only
            // the informational part" rule `DuplicateTripStrip`/
            // `ItineraryTabView.conflictBanner` already use).
            .accessibilityElement(children: .combine)
            // `Spacer` is HStack-only (same reasoning as `TripCard
            // .topLayout`'s identical guard) — inside the VStack variant it
            // would expand vertically and blow out this row's height.
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: Spacing.sm)
            }
            HStack(spacing: Spacing.lg) {
                Button("Keep both") { dismissedIds.insert(pair.id) }
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    .frame(minHeight: 44)
                Button("Merge") { pairPendingConfirm = pair }
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(minHeight: 44)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
