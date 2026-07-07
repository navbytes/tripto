import SwiftData
import SwiftUI

/// Home / trip list (BUILD_PLAN.md §4.1). Renders straight from the local
/// SwiftData mirror via `@Query` — no awaiting the network (SYNC_DESIGN.md
/// Principle 1) — while `SyncEngine` pulls/pushes in the background and
/// `SyncStatus` drives the offline banner and per-card pending chips.
struct HomeView: View {
    @Query(sort: \Trip.startDate) private var trips: [Trip]
    @Query private var profiles: [Profile]
    @Query private var tripMembers: [TripMember]
    @Query private var tripProfiles: [TripProfile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus

    @State private var selectedTab = "Upcoming"
    @State private var isPresentingCreate = false
    @State private var editingTrip: Trip?
    @State private var tripPendingDeletion: Trip?

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()

                VStack(spacing: 0) {
                    if syncStatus.isOffline {
                        SyncBanner()
                    }

                    header
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.md)
                        .padding(.bottom, Spacing.sm)

                    SegmentedControl(options: ["Upcoming", "Past"], selection: $selectedTab)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.xs)

                    if trips.isEmpty {
                        emptyState
                    } else {
                        tripList
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Reset local cache (re-pull)") {
                            Task { await syncEngine?.resetLocalStore() }
                        }
                        Button("Sign out", role: .destructive) {
                            Task { await authManager.signOut() }
                        }
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
                #endif
            }
            .sheet(isPresented: $isPresentingCreate) {
                TripFormView(mode: .create)
            }
            .sheet(item: $editingTrip) { trip in
                TripFormView(mode: .edit(trip))
            }
            .confirmationDialog(
                "Delete trip",
                isPresented: Binding(
                    get: { tripPendingDeletion != nil },
                    set: { isPresented in if !isPresented { tripPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete trip", role: .destructive) {
                    if let trip = tripPendingDeletion { delete(trip) }
                    tripPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { tripPendingDeletion = nil }
            } message: {
                if let trip = tripPendingDeletion {
                    Text("This removes \u{201C}\(trip.title)\u{201D} and everything in it for everyone on the trip.")
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(Typo.body(weight: .medium))
                    .foregroundStyle(Palette.slate)
                Text("Your trips")
                    .font(Typo.display())
                    .foregroundStyle(Palette.ink)
            }
            Spacer()
            Circle()
                .fill(Palette.indigo)
                .frame(width: 42, height: 42)
                .overlay {
                    Text(initials(from: myProfile?.displayName ?? "Traveler"))
                        .font(Typo.display(16))
                        .foregroundStyle(.white)
                }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let period: String
        switch hour {
        case 0..<12: period = "morning"
        case 12..<17: period = "afternoon"
        default: period = "evening"
        }
        let firstName = firstName(from: myProfile?.displayName ?? "Traveler")
        return "Good \(period), \(firstName)"
    }

    private var myProfile: Profile? {
        guard let userId = authManager.userId else { return nil }
        return profiles.first { $0.id == userId }
    }

    // MARK: - List

    private var tripList: some View {
        List {
            ForEach(visibleTrips) { trip in
                NavigationLink {
                    TripPlaceholderView(trip: trip)
                } label: {
                    TripCard(
                        trip: trip,
                        people: people(for: trip),
                        isPending: syncStatus.pendingRowIds.contains(trip.id)
                    )
                    .padding(.horizontal, Spacing.xl)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.bottom, Spacing.lg)
                .swipeActions(edge: .trailing) {
                    if isOrganizer(of: trip) {
                        Button("Delete", role: .destructive) {
                            tripPendingDeletion = trip
                        }
                    }
                }
                .contextMenu {
                    Button("Edit trip") { editingTrip = trip }
                    if isOrganizer(of: trip) {
                        Button("Delete trip", role: .destructive) {
                            tripPendingDeletion = trip
                        }
                    }
                }
            }

            planNewTripRow
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var planNewTripRow: some View {
        Button {
            isPresentingCreate = true
        } label: {
            HStack {
                Spacer()
                Label("Plan a new trip", systemImage: "plus")
                    .font(Typo.body(weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Palette.slate)
            .padding(.vertical, Spacing.lg)
            .background {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .strokeBorder(Palette.mist, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .padding(.horizontal, Spacing.xl)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "airplane.departure")
                .font(.system(size: 40))
                .foregroundStyle(Palette.slate)
            VStack(spacing: Spacing.xs) {
                Text("Plan your first trip")
                    .font(Typo.display(Typo.Size.title))
                    .foregroundStyle(Palette.ink)
                Text("Everyone's plans, one shared itinerary.")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
            }
            Button {
                isPresentingCreate = true
            } label: {
                Text("Plan a new trip")
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
                    .background(Palette.amber, in: Capsule())
            }
            Spacer()
            Spacer()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived data

    private var upcomingTrips: [Trip] {
        trips
            .filter { !$0.bucket().isPastTab }
            .sorted { lhs, rhs in
                let lhsInProgress = lhs.bucket() == .inProgress
                let rhsInProgress = rhs.bucket() == .inProgress
                if lhsInProgress != rhsInProgress { return lhsInProgress }
                return lhs.startDate < rhs.startDate
            }
    }

    private var pastTrips: [Trip] {
        trips.filter { $0.bucket().isPastTab }.sorted { $0.startDate > $1.startDate }
    }

    private var visibleTrips: [Trip] {
        selectedTab == "Upcoming" ? upcomingTrips : pastTrips
    }

    private func people(for trip: Trip) -> [AvatarStack.Person] {
        tripProfiles
            .filter { $0.tripId == trip.id }
            .sorted { $0.createdAt < $1.createdAt }
            .map { profile in
                AvatarStack.Person(
                    id: profile.id,
                    initial: initials(from: profile.displayName),
                    colorName: profile.avatarColor
                )
            }
    }

    private func isOrganizer(of trip: Trip) -> Bool {
        guard let userId = authManager.userId else { return false }
        return tripMembers.contains {
            $0.tripId == trip.id && $0.userId == userId && $0.role == .organizer
        }
    }

    private func firstName(from displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    private func initials(from displayName: String) -> String {
        firstName(from: displayName).prefix(1).uppercased()
    }

    // MARK: - Mutations

    private func delete(_ trip: Trip) {
        let tripId = trip.id
        modelContext.delete(trip)
        // Local cascade mirrors the server's FK cascade (SYNC_DESIGN.md
        // "Write paths") — anything already pulled for this trip goes with
        // it rather than lingering as an orphan until the next pull.
        for member in tripMembers where member.tripId == tripId {
            modelContext.delete(member)
        }
        for profile in tripProfiles where profile.tripId == tripId {
            modelContext.delete(profile)
        }
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .trips, rowId: tripId, tripId: tripId) }
    }
}
