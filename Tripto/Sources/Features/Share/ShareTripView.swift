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
    /// Bug fix: the card used to only offer "Reset link" (revoke +
    /// immediately create a replacement) — no way to just turn the link
    /// off. Mirrors `invitePendingRevoke`'s "revoke, no replacement"
    /// pattern below.
    @State private var linkPendingRemoval: TripShareLink?
    @State private var memberPendingRoleChange: TripMember?
    @State private var memberPendingOrganizerConfirm: TripMember?
    @State private var memberPendingRemoval: TripMember?
    @State private var invitePendingRevoke: Invite?
    /// Guards the deliberate network-bound share-link create/reset (see the
    /// "Mutations" doc comment below) — without this, a double-tap on
    /// "Create view link" fires two concurrent inserts. Kept in the Button
    /// actions themselves, not inside `createShareLink()`, so the DEBUG
    /// autopilot and `resetShareLink()` aren't blocked by a reentrancy guard.
    @State private var busyShareLink = false
    /// Same as `busyShareLink`, per-role, for the two invite buttons.
    @State private var busyInviteRoles: Set<TripRole> = []
    /// M4: "Add someone without the app" / edit-existing-profile sheets
    /// (this milestone's brief §2) — both drive `TripProfileFormSheet`.
    @State private var isPresentingAddProfile = false
    @State private var editingProfile: TripProfile?
    /// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): this trip's real import address,
    /// fetched once per screen visit and cached here — see
    /// `fetchImportAddressIfNeeded()`. Mirrors `ItineraryTabView`'s own
    /// `importLoadState`/`hasFetchedImportAddress` pair (deliberately not
    /// shared state — each screen fetches independently), so the
    /// forwarding-address card stays reachable here even once the itinerary
    /// has items and its own teaser has stopped rendering.
    ///
    /// A5 (`docs/BACKLOG.md`): starts `.needsConsent` (not `.loading`) when
    /// email-import consent isn't on record yet — see `ItineraryTabView`'s
    /// matching property doc comment for why this is resolved synchronously
    /// here rather than inside `fetchImportAddressIfNeeded()`. "Each screen
    /// fetches independently" above now also means each screen re-reads
    /// `EmailImportConsent.isGranted()` independently at its own first
    /// appearance — granting on one screen updates the OTHER screen's card
    /// only the next time that screen's own view identity is freshly
    /// created, same class of staleness this pair already accepted for the
    /// fetch result itself.
    @State private var importLoadState: ImportAddressCard.LoadState = EmailImportConsent.isGranted() ? .loading : .needsConsent
    @State private var hasFetchedImportAddress = false
    /// TI-2: "Or paste text instead" — the fallback path below
    /// `importCard`'s email-address card, presenting `PasteImportSheet`
    /// in `.booking` mode.
    @State private var isPresentingPasteImport = false

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
            VStack(alignment: .leading, spacing: Spacing.xl) {
                shareLinkCard
                inviteSection
                importCard
                peopleSection
            }
            .padding(Spacing.xl)
        }
        .background(Palette.paper)
        .navigationTitle("Share this trip")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay($toast)
        .activityShareSheet(items: $shareSheetItems)
        // TI-2/TI-3: the fallback path beside `importCard`'s email-address
        // card — not one of the three tabs the paste-import consistency
        // pass (TripView.pasteImportPill) targeted, left as its own entry
        // point here, just updated to the unified sheet's new signature.
        .sheet(isPresented: $isPresentingPasteImport) {
            PasteImportSheet(
                tripId: tripId,
                onItineraryItemsImported: { created in
                    toast = "\(created) item\(created == 1 ? "" : "s") added to review"
                },
                onPackingConfirmed: { candidates in
                    // Bug fix (review): a bare `guard let userId =
                    // authManager.userId else { return }` silently dropped
                    // every confirmed item with no toast when signed out —
                    // `?? trips.first?.createdBy` matches the fallback
                    // `TripView`/`PackingListView.addItem` already use for
                    // exactly this signed-out-local-creator case.
                    let creatorId = authManager.userId ?? trips.first?.createdBy
                    guard let creatorId else { return }
                    for candidate in candidates {
                        PackingItem.insert(
                            label: candidate.label, groupKey: candidate.groupKey, assigneeProfileId: nil,
                            tripId: tripId, createdBy: creatorId,
                            modelContext: modelContext, syncEngine: syncEngine
                        )
                    }
                    toast = "\(candidates.count) item\(candidates.count == 1 ? "" : "s") added to packing list"
                }
            )
        }
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
        // Reviewer should-fix: `myRole` (below) is derived from `@Query
        // members`, which can still be empty on first render (fresh
        // install, just-joined trip, this screen opened before member sync
        // completes) — a plain one-shot `.task` here fired once with
        // `myRole == nil`, the gate inside `fetchImportAddressIfNeeded()`
        // failed, and `hasFetchedImportAddress` was left `false` forever
        // (the early return never sets it), so once `members` synced in and
        // `importCard` started rendering, nothing ever re-fetched — a
        // permanent loading spinner for the rest of that visit. Re-running
        // on every `myRole` change fixes that: the guard inside the
        // function still no-ops once a fetch has actually been attempted,
        // so this only ever causes a retry in the false/unknown -> true
        // transition.
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

    /// `shareLinkCard`'s text scrim (UX audit finding 1). Unlike `TripCard`'s
    /// `CoverGradient.textScrim` — a vertical, bottom-heavy ramp built for
    /// text that sits at the bottom of that card — this card's title/
    /// description sit at the TOP-LEADING corner, `CoverGradient.dusk`'s
    /// lightest stop (#E8955A, ~2.4:1 for white per `Palette.onAmber`'s doc).
    /// A bottom-heavy scrim would darken the wrong corner, so this is a
    /// diagonal ramp along `.dusk`'s own axis (`.topLeading` ->
    /// `.bottomTrailing`) instead. Black 0.45 composited over #E8955A yields
    /// L~0.108 => ~6.6:1 for full white and ~5.3:1 for the description's
    /// `.white.opacity(0.9)`, clearing WCAG AA (4.5:1); the bottom fine-print
    /// already sits over dark indigo/plum and is unaffected. Fixed (not
    /// theme-adaptive), same rationale as `CoverGradient.textScrim`: cover
    /// gradients don't change between light and dark.
    ///
    /// This would normally live as a `CoverGradient` companion next to
    /// `textScrim` in `Design/PaletteExtras.swift` (same file/rationale —
    /// `gen_tokens.py` never touches it), but this pass is scoped to the
    /// Share screen's own files only (concurrent work on other screens is
    /// touching `Design/` files elsewhere on this branch), so it's kept
    /// local here. Worth hoisting into `PaletteExtras.swift` in a later,
    /// non-concurrent pass if `TripCard` or another cover-gradient card ever
    /// needs the same top-leading treatment.
    private static let shareLinkCardScrim = LinearGradient(
        stops: [
            .init(color: .black.opacity(0.45), location: 0.0),
            .init(color: .clear, location: 0.6)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Share link card (top gradient card)

    private var shareLinkCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "link")
                    .accessibilityHidden(true)
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
                HStack(spacing: Spacing.lg) {
                    Button("Reset link") { isPresentingResetConfirm = true }
                        .foregroundStyle(.white.opacity(0.85))
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                    Button("Remove link") { linkPendingRemoval = link }
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                }
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .disabled(busyShareLink)
            } else if busyShareLink {
                HStack(spacing: Spacing.sm) {
                    ProgressView().tint(Self.onWhitePillInk)
                    Text("Creating link\u{2026}")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Self.onWhitePillInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(.white, in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
            } else {
                Button {
                    Task {
                        busyShareLink = true
                        _ = await createShareLink()
                        busyShareLink = false
                    }
                } label: {
                    Text("Create view link")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Self.onWhitePillInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                        .background(.white, in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busyShareLink)
            }

            Text("Booking codes and notes never appear on this link.")
                .font(Typo.body(10.5))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: Radii.card + 4, style: .continuous)
                .fill(CoverGradient.dusk)
                .overlay { Self.shareLinkCardScrim }
                .clipShape(RoundedRectangle(cornerRadius: Radii.card + 4, style: .continuous))
        }
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
                // States the action rather than the bare "Copy" (finding:
                // out of context — e.g. right after a page's Edit/Copy —
                // the label alone doesn't say what's being copied).
                .accessibilityLabel("Copy link")

            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: shareIconFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: shareIconDiameter, height: shareIconDiameter)
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

    // MARK: - Import card

    /// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): a persistent copy of
    /// `ItineraryTabView`'s import teaser — that one only renders while the
    /// itinerary has zero items, so once any item exists the forwarding
    /// address becomes unreachable there. This card lives alongside the
    /// other copyable tokens on this screen (share link, invite links) so
    /// it's always reachable. Gated on `ItemPermissions.canAdd` — same
    /// permission check `addProfileButton` above uses — since only an
    /// organizer/companion can usefully forward confirmations into the
    /// itinerary; a viewer sees neither this card nor the teaser's `canEdit`
    /// equivalent.
    @ViewBuilder
    private var importCard: some View {
        if ItemPermissions.canAdd(role: myRole) {
            VStack(alignment: .center, spacing: Spacing.sm) {
                ImportAddressCard(state: importLoadState) { address in
                    toast = ClipboardFeedback.copy(address, label: "Import address")
                } onRetry: {
                    retryImportAddressFetch()
                } onConsentGranted: {
                    grantEmailImportConsentAndFetch()
                }
                pasteImportSecondaryAction
            }
        }
    }

    /// TI-2: a deliberately lightweight fallback beside the primary
    /// email-import card — pasting text is the secondary path, so this is a
    /// plain text button, not another card competing for attention.
    private var pasteImportSecondaryAction: some View {
        Button {
            isPresentingPasteImport = true
        } label: {
            Text("Or paste text instead")
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Same one-shot-per-visit *shape* as `ItineraryTabView`'s function of
    /// the same name, but gated on `ItemPermissions.canAdd` (not `canEdit`)
    /// — deliberately different from the teaser's gate: the RPC requires
    /// trip membership, so fetching for a viewer or signed-out user would
    /// just fail/spin for someone who can never see `importCard` anyway.
    ///
    /// Unlike `ItineraryTabView`'s `canEdit` (a plain `let`, synchronously
    /// known at init), `myRole` here is derived from `@Query members`,
    /// which resolves *asynchronously* and can still be empty the first
    /// time this runs — that's why the `.task(id: myRole)` above re-invokes
    /// this on every `myRole` change rather than firing once, and why
    /// `hasFetchedImportAddress` must only ever be set `true` once a fetch
    /// has actually been attempted (never inside this guard's early
    /// return), so a gate that starts `false` and later flips `true` still
    /// gets its one real attempt.
    /// A5 (`docs/BACKLOG.md`): the new second guard clause is the actual
    /// fetch gate — see `ItineraryTabView.fetchImportAddressIfNeeded()`'s
    /// matching doc comment (identical reasoning, including why
    /// `hasFetchedImportAddress` is deliberately NOT set on the
    /// not-yet-consented path).
    private func fetchImportAddressIfNeeded() async {
        guard ItemPermissions.canAdd(role: myRole), !hasFetchedImportAddress else { return }
        guard EmailImportConsent.fetchDecision() == .fetchImmediately else { return }
        hasFetchedImportAddress = true
        await fetchImportAddress()
    }

    /// The actual RPC call, split out from the one-shot guard above so
    /// `retryImportAddressFetch()` can re-run it without re-triggering
    /// `hasFetchedImportAddress`'s guard.
    private func fetchImportAddress() async {
        do {
            importLoadState = .loaded(try await TripImportAddress.fetch(tripId: tripId))
        } catch {
            importLoadState = .failed
        }
    }

    /// Reviewer should-fix: `importCard`'s tap-to-retry action on a
    /// `.failed` state.
    private func retryImportAddressFetch() {
        importLoadState = .loading
        Task { await fetchImportAddress() }
    }

    /// A5 (`docs/BACKLOG.md`): `importCard`'s `.needsConsent` card ->
    /// `onConsentGranted` — see `ItineraryTabView.grantEmailImportConsentAndFetch()`'s
    /// matching doc comment (identical shape).
    private func grantEmailImportConsentAndFetch() {
        EmailImportConsent.grant()
        hasFetchedImportAddress = true
        retryImportAddressFetch()
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
                    .accessibilityHidden(true)
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
            // Non-interactive info card — one VoiceOver stop instead of icon
            // + two texts.
            .accessibilityElement(children: .combine)
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
            Image(systemName: info.icon)
                .font(.system(size: captionIconSize, weight: .semibold))
                .accessibilityHidden(true)
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
                Button {
                    memberPendingRoleChange = member
                } label: {
                    roleBadgeLabel(info)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                // Role picker row: states the current value and what
                // tapping does, rather than the badge's icon/text alone.
                .accessibilityLabel("Role: \(info.label)")
                .accessibilityHint("Opens the role picker for \(name)")
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
                // Decorative — the name `Text` right after already carries
                // this identity.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(Typo.body(weight: .semibold)).foregroundStyle(Palette.ink)
                Text("No account yet").font(Typo.body(Typo.Size.caption)).foregroundStyle(Palette.slate)
            }
            Spacer(minLength: Spacing.sm)
            PillLabel(text: "Can be assigned plans \u{00B7} no app needed", tint: .neutral)
            if isOrganizer {
                Image(systemName: "chevron.right")
                    .font(.system(size: captionIconSize, weight: .semibold))
                    .foregroundStyle(Palette.slate.opacity(0.5))
                    // Decorative disclosure indicator — the wrapping
                    // Button's own trait already conveys "tappable".
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())

        return Group {
            if isOrganizer {
                Button { editingProfile = profile } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens their profile to edit")
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
            if let pg = error as? PostgrestError, pg.code == "42501" {
                toast = "Couldn\u{2019}t create the link yet \u{2014} this trip is still syncing. Try again in a moment."
            } else {
                toast = "Couldn\u{2019}t create a share link \u{2014} check your connection."
            }
            return nil
        }
    }

    /// Creates the replacement link **before** revoking the old one, so
    /// `activeShareLink` (`shareLinks.first { !revoked }`) never goes empty
    /// mid-reset — the old create-then-revoke order let `shareLinkCard`
    /// flash back to its "Create view link" empty state for a frame
    /// (finding 2/3).
    private func resetShareLink() {
        Task {
            busyShareLink = true
            defer { busyShareLink = false }
            let old = activeShareLink
            if await createShareLink() != nil {
                if let old {
                    old.revoked = true
                    try? modelContext.save()
                    let dto = old.toDTO()
                    let id = old.id
                    await syncEngine?.enqueueUpsert(table: .shareLinks, rowId: id, tripId: tripId, payload: dto)
                }
                toast = "Link reset"
            }
        }
    }

    /// "Remove link" — revoke with no replacement, unlike `resetShareLink`.
    /// Same local-write-then-enqueue shape as `revokeInvite`; no
    /// `busyShareLink` guard needed since (unlike reset/create) this never
    /// makes a network round trip itself before the local write.
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
    var onRemove: (() -> Void)?

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
        Option(role: .viewer, icon: "eye.fill", color: CategoryColor.flight.fg, description: TripRole.viewer.capabilityDescription)
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
                                .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    // Role picker row: value states whether it's the
                    // current role, hint carries the capability description
                    // (visible on screen either way) rather than folding it
                    // into the label.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(option.role.rawValue.capitalized)
                    .accessibilityValue(option.role == currentRole ? "Selected" : "")
                    .accessibilityHint(option.description)
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
