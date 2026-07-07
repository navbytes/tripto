import Foundation
import SwiftData

/// The one `Schema` covering every mirrored table plus sync bookkeeping —
/// shared by the production `ModelContainer` (`TriptoApp`), `SyncStore`
/// (via the same container instance), and tests (in-memory).
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Profile.self,
        Trip.self,
        TripMember.self,
        TripProfile.self,
        ItineraryItem.self,
        PackingItem.self,
        TripShareLink.self,
        Invite.self,
        OutboxOp.self,
        SyncIssue.self,
    ]

    static var schema: Schema { Schema(models) }

    /// `inMemory: true` is for tests and previews — nothing persists past
    /// the process, so each gets a clean store with no fixture bleed.
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
