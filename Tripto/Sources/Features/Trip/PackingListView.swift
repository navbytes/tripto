import SwiftData
import SwiftUI

/// The shared, assignable packing list (BUILD_PLAN.md §3.3, §5.4;
/// docs/TripAppFamily.jsx's `Packing` screen is the visual reference) —
/// rendered as `TripView`'s third content tab. Progress header,
/// grouped rows (checkbox/label/assignee), an add sheet, and role-gated
/// mutations (`PackingPermissions`) — everything here follows the same
/// "SwiftData write on the main context, then `SyncEngine.enqueue`" flow
/// every other mutation in the app uses.
struct PackingListView: View {
    let tripId: UUID
    /// The trip's `createdBy` — the signed-out user IS the local trip
    /// creator (see `TripView.canAddItems`'s doc comment), so this is
    /// their own uid from when they created the trip; the later push will
    /// satisfy RLS once they sign back in, same story as
    /// `AddItemSheet.tripCreatedBy`.
    let tripCreatedBy: UUID
    /// Finding 2: true while this trip's first pull this session hasn't
    /// completed yet — see `TripView.awaitingFirstTripPull`'s doc comment.
    var isAwaitingFirstSync: Bool = false

    @Query private var packingItems: [PackingItem]
    @Query private var tripProfiles: [TripProfile]
    @Query private var members: [TripMember]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager

    @State private var isPresentingAdd = false
    @State private var toast: String?
    @State private var reassigningItem: PackingItem?

    init(tripId: UUID, tripCreatedBy: UUID, isAwaitingFirstSync: Bool = false) {
        self.tripId = tripId
        self.tripCreatedBy = tripCreatedBy
        self.isAwaitingFirstSync = isAwaitingFirstSync
        _packingItems = Query(filter: #Predicate<PackingItem> { $0.tripId == tripId })
        _tripProfiles = Query(filter: #Predicate<TripProfile> { $0.tripId == tripId })
        _members = Query(filter: #Predicate<TripMember> { $0.tripId == tripId })
    }

    private var myRole: TripRole? {
        guard let userId = authManager.userId else { return nil }
        return members.first { $0.userId == userId }?.role
    }

    /// Role gate for add/toggle/reassign (`PackingPermissions.canManage`) —
    /// convenience only (CLAUDE.md); RLS enforces the real boundary.
    ///
    /// Finding 1: adopts the exact "signed out ⇒ legitimately-permitted
    /// local creator" rule `TripView.canAddItems` already codifies (see its
    /// doc comment) — `PackingPermissions.canManage` alone reads `nil`
    /// `myRole` as "can't manage," which was demoting a signed-out local
    /// creator to read-only on their own trip's packing list.
    /// `PackingPermissions` itself is intentionally left untouched: it
    /// mirrors the live RLS policies, and "signed out" is a client-session
    /// concept RLS has no notion of — so the override lives here, at the
    /// view layer, not in that model.
    private var canManage: Bool {
        guard authManager.userId != nil else { return true }
        return PackingPermissions.canManage(role: myRole)
    }

    private var summary: PackingProgress.Summary { PackingProgress.summary(for: packingItems) }
    private var groups: [(key: PackingGroupKey, items: [PackingItem])] { PackingGrouping.groups(for: packingItems) }

    var body: some View {
        Group {
            if packingItems.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    progressHeader
                    Rectangle().fill(Palette.mist).frame(height: 1)
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        // Packing is a TripView tab now (not a pushed screen), and TripView
        // hides the nav bar for its gradient hero — so the add affordance is an
        // in-content FAB matching the itinerary tab, not a nav-bar button.
        .overlay(alignment: .bottomTrailing) {
            if canManage && !packingItems.isEmpty {
                Fab(action: { isPresentingAdd = true }, accessibilityLabel: "Add packing item")
                    .padding(.trailing, Spacing.xl)
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .sheet(isPresented: $isPresentingAdd) {
            PackingItemFormSheet(tripProfiles: tripProfiles) { label, groupKey, assigneeProfileId in
                addItem(label: label, groupKey: groupKey, assigneeProfileId: assigneeProfileId)
            }
        }
        .confirmationDialog(
            "Reassign to",
            isPresented: Binding(
                get: { reassigningItem != nil },
                set: { isPresented in if !isPresented { reassigningItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unassigned") {
                if let item = reassigningItem { reassign(item, to: nil) }
                reassigningItem = nil
            }
            ForEach(tripProfiles) { profile in
                Button(profile.displayName) {
                    if let item = reassigningItem { reassign(item, to: profile.id) }
                    reassigningItem = nil
                }
            }
            Button("Cancel", role: .cancel) { reassigningItem = nil }
        }
        // UX audit finding 8 (this tab): mirrors TripView.swift's own
        // finding-8 fix — this tab renders its own FAB in the same band, so
        // its toast needs the same constant FAB-clearance inset.
        .toastOverlay($toast, bottomInset: Fab.scrollClearance)
        .task {
            #if DEBUG
            await applyUITestAutopilotIfNeeded()
            #endif
        }
    }

    // MARK: - Progress header (this milestone's brief: "'{done} of {total}
    // packed', %, gradient bar")

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(summary.done) of \(summary.total) packed")
                    .font(Typo.display(20))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: Spacing.sm)
                Text("\(summary.percent)%")
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.amber)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.mist)
                    Capsule()
                        .fill(CoverGradient.dusk)
                        .frame(width: geometry.size.width * CGFloat(summary.percent) / 100)
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Grouped list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                HeroScrollSentinel()
                ForEach(groups, id: \.key) { group in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: group.key.symbolName)
                                .font(.system(size: 11, weight: .bold))
                            Text(group.key.displayName.uppercased())
                                .font(Typo.body(12, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundStyle(Palette.slate)

                        VStack(spacing: Spacing.sm) {
                            ForEach(group.items) { item in
                                row(item)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.xl)
            // UX audit finding 4: matches the FAB clearance the itinerary/
            // bookings scroll views use — this tab's own FAB sits in the
            // same band, so its last row deserves the same headroom.
            .padding(.bottom, Fab.scrollClearance)
        }
        .coordinateSpace(.named(HeroCollapse.scrollSpace))
    }

    private func row(_ item: PackingItem) -> some View {
        HStack(spacing: Spacing.md) {
            Button {
                toggleDone(item)
            } label: {
                HStack(spacing: Spacing.md) {
                    checkbox(for: item)
                    Text(item.label)
                        .font(Typo.body(Typo.Size.body, weight: .semibold))
                        .foregroundStyle(item.isDone ? Palette.slate : Palette.ink)
                        .strikethrough(item.isDone)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canManage)

            Button {
                reassigningItem = item
            } label: {
                assigneeChip(for: item)
            }
            .buttonStyle(.plain)
            .disabled(!canManage)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous).stroke(Palette.mist, lineWidth: 1)
        }
        .opacity(item.isDone ? 0.65 : 1)
        .swipeActions(edge: .trailing) {
            // Finding 1: same signed-out-creator override as `canManage` —
            // without it, a signed-out creator could add/toggle/reassign an
            // item but not delete it, recreating the same inconsistency one
            // level down.
            if authManager.userId == nil || PackingPermissions.canDelete(item: item, role: myRole, userId: authManager.userId) {
                Button("Delete", role: .destructive) { delete(item) }
            }
        }
    }

    private func checkbox(for item: PackingItem) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(item.isDone ? CategoryColor.activity.fg : Color.clear)
            .frame(width: 24, height: 24)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(item.isDone ? Color.clear : Palette.mist, lineWidth: 2)
            }
            .overlay {
                if item.isDone {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
            }
    }

    private func assigneeChip(for item: PackingItem) -> some View {
        let profile = item.assigneeProfileId.flatMap { id in tripProfiles.first { $0.id == id } }
        return HStack(spacing: 6) {
            Circle()
                .fill(profile.map { AvatarColor.color(named: $0.avatarColor) } ?? Palette.mist)
                .frame(width: 22, height: 22)
                .overlay {
                    if let profile {
                        Text(initials(from: profile.displayName))
                            .font(Typo.body(10, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.slate)
                    }
                }
            Text(profile.map { firstName(from: $0.displayName) } ?? "Unassigned")
                .font(Typo.body(11.5, weight: .semibold))
                .foregroundStyle(Palette.slate)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, Spacing.sm)
        .padding(.vertical, 4)
        .background(Palette.paper, in: Capsule())
    }

    // MARK: - Empty state (§6.6: invitation copy, not blank)

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            if isAwaitingFirstSync {
                // Finding 2: a freshly-claimed (or just-opened) trip's
                // packing list can't yet be told apart from a genuinely
                // empty one while its first pull is still in flight — this
                // neutral placeholder (no CTA, no claim either way) mirrors
                // `HomeView.initialLoadState`'s "Checking for your trips…"
                // instead of asserting "start the list" before the answer
                // is known.
                ProgressView()
                Text("Checking the packing list\u{2026}")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
            } else {
                Image(systemName: "bag.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(Palette.slate)
                VStack(spacing: Spacing.xs) {
                    Text("Start the family packing list")
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                    Text(
                        canManage
                            ? "Passports, the car seat, chargers everyone forgets \u{2014} add what this trip needs."
                            : "The organizer hasn\u{2019}t added anything yet."
                    )
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.xl)
                if canManage {
                    Button {
                        isPresentingAdd = true
                    } label: {
                        Text("Add an item")
                            .font(Typo.body(weight: .semibold))
                            .foregroundStyle(Palette.onAmber)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.md)
                            .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
                            .contentShape(Capsule())
                            .background(Palette.amber, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Spacer()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived

    private func firstName(from displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    private func initials(from displayName: String) -> String {
        firstName(from: displayName).prefix(1).uppercased()
    }

    // MARK: - Mutations

    private func toggleDone(_ item: PackingItem) {
        guard canManage else { return }
        item.isDone.toggle()
        item.updatedAt = .now
        item.updatedBy = authManager.userId
        try? modelContext.save()
        enqueue(item)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func reassign(_ item: PackingItem, to profileId: UUID?) {
        guard canManage else { return }
        item.assigneeProfileId = profileId
        item.updatedAt = .now
        item.updatedBy = authManager.userId
        try? modelContext.save()
        enqueue(item)
    }

    /// Finding 1: dropped the `authManager.userId` hard guard — it made
    /// this silently no-op for a signed-out local creator (`canManage`
    /// already grants them the add). `createdBy` falls back to
    /// `tripCreatedBy` (the signed-out creator's own uid) when there's no
    /// signed-in session, and the toast is qualified so the fact that it
    /// hasn't synced anywhere yet is honest, not silent.
    private func addItem(label: String, groupKey: PackingGroupKey, assigneeProfileId: UUID?) {
        guard canManage, !label.isEmpty else { return }
        let now = Date()
        let creatorId = authManager.userId ?? tripCreatedBy
        let item = PackingItem(
            id: UUID(), tripId: tripId, label: label, groupKeyRaw: groupKey.rawValue,
            assigneeProfileId: assigneeProfileId, isDone: false, createdBy: creatorId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        modelContext.insert(item)
        try? modelContext.save()
        enqueue(item)
        toast = authManager.userId == nil
            ? "Added to packing list \u{2014} you\u{2019}re signed out, so it won\u{2019}t sync until you sign back in."
            : "Added to packing list"
    }

    private func delete(_ item: PackingItem) {
        let rowId = item.id
        modelContext.delete(item)
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .packingItems, rowId: rowId, tripId: tripId) }
    }

    private func enqueue(_ item: PackingItem) {
        let dto = item.toDTO()
        let rowId = item.id
        Task { await syncEngine?.enqueueUpsert(table: .packingItems, rowId: rowId, tripId: tripId, payload: dto) }
    }

    // MARK: - DEBUG verify-drill autopilot

    #if DEBUG
    /// M4 verify drill: toggles one seeded (not-yet-done) packing item and
    /// assigns another seeded (not-yet-assigned) one to "Meera" — proves
    /// both a toggle and an assignment reach the server, with no GUI tap
    /// automation available in this environment (see `WelcomeView`/
    /// `HomeView`'s matching `-uitest…` doc comments). Matched by
    /// `DemoSeeder`'s exact labels rather than "first"/"second" — `@Query`
    /// carries no explicit sort here, so positional indexing into
    /// `packingItems` would be unpredictable.
    private func applyUITestAutopilotIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-uitestTogglePacking") else { return }
        if let boardingPasses = packingItems.first(where: { $0.label == "Boarding passes" }) {
            toggleDone(boardingPasses)
        }
        if let charger = packingItems.first(where: { $0.label == "Portable phone charger" }),
            charger.assigneeProfileId == nil,
            let meera = tripProfiles.first(where: { $0.displayName.hasPrefix("Meera") }) {
            reassign(charger, to: meera.id)
        }
    }
    #endif
}

/// Add-item sheet (this milestone's brief: "Add-item affordance (label +
/// group + optional assignee)"). A plain closure callback (`onSave`), not a
/// direct SwiftData/sync dependency, so this stays a dumb form the same way
/// `RolePickerSheet` (ShareTripView.swift) does.
private struct PackingItemFormSheet: View {
    let tripProfiles: [TripProfile]
    let onSave: (_ label: String, _ groupKey: PackingGroupKey, _ assigneeProfileId: UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var groupKey: PackingGroupKey = .shared
    @State private var assigneeProfileId: UUID?

    private var isValid: Bool { !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.mist).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        FormTextField(label: "Item", text: $label, placeholder: "Passports, car seat, chargers\u{2026}")

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Group")
                                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                                .foregroundStyle(Palette.slate)
                            HStack(spacing: Spacing.sm) {
                                ForEach(PackingGrouping.order, id: \.self) { key in
                                    groupTile(key)
                                }
                            }
                        }

                        if !tripProfiles.isEmpty {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Assign to (optional)")
                                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                                    .foregroundStyle(Palette.slate)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: Spacing.sm) {
                                        assigneeTile(nil, label: "Unassigned", colorName: nil)
                                        ForEach(tripProfiles) { profile in
                                            assigneeTile(profile.id, label: firstName(from: profile.displayName), colorName: profile.avatarColor)
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            onSave(label.trimmingCharacters(in: .whitespacesAndNewlines), groupKey, assigneeProfileId)
                            dismiss()
                        } label: {
                            Text("Add to packing list")
                                .font(Typo.body(weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(Palette.onAmber)
                                .padding(.vertical, Spacing.md)
                                .background(Palette.amber, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isValid)
                        .opacity(isValid ? 1 : 0.5)
                        .padding(.top, Spacing.xs)
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.slate)
                // Finding 3b: 44pt hit band (§6.5) — same
                // PersonFilterBar.swift compensation move as below.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            Spacer()
            Text("Add packing item")
                .font(Typo.body(weight: .bold))
                .foregroundStyle(Palette.ink)
            Spacer()
            Text("Cancel").font(Typo.body(weight: .semibold)).opacity(0) // balances the leading button
                .frame(minHeight: 44)
        }
        .padding(.horizontal, Spacing.lg)
        // Finding 3b: trimmed from Spacing.md/.sm to .xs/.xs — the Cancel
        // button's new 44pt hit band grows the row, so this keeps the
        // header's total height roughly unchanged (PersonFilterBar.swift's
        // same trade-off).
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.xs)
    }

    private func groupTile(_ key: PackingGroupKey) -> some View {
        let isOn = groupKey == key
        return Button {
            groupKey = key
        } label: {
            VStack(spacing: 4) {
                Image(systemName: key.symbolName).font(.system(size: 15, weight: .medium))
                Text(key.displayName).font(Typo.body(10.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? CategoryColor.activity.fg : Palette.slate)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(isOn ? CategoryColor.activity.soft : Palette.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isOn ? CategoryColor.activity.fg : Palette.mist, lineWidth: 1.25)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func assigneeTile(_ id: UUID?, label text: String, colorName: String?) -> some View {
        let isOn = assigneeProfileId == id
        return Button {
            assigneeProfileId = id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(colorName.map { AvatarColor.color(named: $0) } ?? Palette.mist)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if colorName != nil {
                            Text(text.prefix(1).uppercased())
                                .font(Typo.body(9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text(text).font(Typo.body(12.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? .white : Palette.slate)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .background(isOn ? Palette.indigo : Palette.elevated, in: Capsule())
            .overlay {
                Capsule().stroke(isOn ? Color.clear : Palette.mist, lineWidth: 1)
            }
            // Finding 3a: same 44pt hit band as PersonFilterBar's chips
            // (§6.5) — visuals unchanged, hit area compliant.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func firstName(from displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }
}
