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
            }
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

    private func displayName(for member: TripMember) -> String {
        profile(for: member)?.displayName ?? "Traveler"
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

    @ViewBuilder
    private var inviteSection: some View {
        // Organizer-only, same RLS reality as the share link (`Invite`'s
        // doc comment) — a non-organizer would only ever see `[]` here, so
        // the whole section (not just a muted message) is hidden for them.
        if isOrganizer {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Invite to edit or view")
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.slate)
                    .textCase(.uppercase)

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
            }
        }
    }

    private func inviteButton(role: TripRole, title: String, icon: String, color: Color) -> some View {
        Button {
            Task { _ = await createInvite(role: role) }
        } label: {
            HStack {
                Image(systemName: icon)
                Text(title).font(Typo.body(weight: .semibold))
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
            Button("Revoke", role: .destructive) { revokeInvite(invite) }
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
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
        }
    }

    private func memberRow(_ member: TripMember) -> some View {
        let isSelf = member.userId == authManager.userId
        let name = displayName(for: member)
        let colorName = profile(for: member)?.avatarColor ?? "slate"
        let info = roleBadge(for: member.role)
        let canManage = MemberRolePermissions.canChangeRole(actingRole: myRole, targetIsSelf: isSelf)

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
                    if isSelf {
                        Text("\u{00B7} you").font(Typo.body(weight: .medium)).foregroundStyle(Palette.slate)
                    }
                }
                Text(member.role == .organizer ? "created the trip" : "joined")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }

            Spacer(minLength: Spacing.sm)

            Button {
                memberPendingRoleChange = member
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: info.icon).font(.system(size: 11, weight: .semibold))
                    Text(info.label).font(Typo.body(Typo.Size.caption, weight: .bold))
                }
                .foregroundStyle(info.color)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(info.color.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canManage)
        }
        .padding(.vertical, Spacing.sm)
        .swipeActions(edge: .trailing) {
            if canManage {
                Button("Remove", role: .destructive) { memberPendingRemoval = member }
            }
        }
    }

    private func unlinkedProfileRow(_ profile: TripProfile) -> some View {
        HStack(spacing: Spacing.md) {
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
            PillLabel(text: "Assignable \u{00B7} no account", tint: .neutral)
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

    @Environment(\.dismiss) private var dismiss

    private struct Option {
        let role: TripRole
        let icon: String
        let color: Color
        let description: String
    }

    private let options: [Option] = [
        Option(role: .organizer, icon: "crown.fill", color: Palette.amber, description: "Full control \u{2014} edit everything, manage people."),
        Option(role: .companion, icon: "pencil", color: CategoryColor.activity.fg, description: "Add plans, suggest, comment, edit their own items."),
        Option(role: .viewer, icon: "eye.fill", color: CategoryColor.flight.fg, description: "See the itinerary \u{2014} no editing. Great for kids & grandparents."),
    ]

    var body: some View {
        NavigationStack {
            List(options, id: \.role) { option in
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
