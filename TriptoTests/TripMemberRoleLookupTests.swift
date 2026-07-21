import SwiftData
import XCTest
@testable import Tripto

/// Reviewer MEDIUM (app-intents deepening, verify wave): `AddToPackingIntent`
/// must gate on the same `PackingPermissions.canManage` predicate manual add
/// uses (`PackingListView.swift:158`) — an intent must never claim success a
/// write RLS is about to reject (same invariant as the suggest-mode paste
/// gate fixed in #60). `TripMemberRoleLookup` is the one SwiftData read
/// behind that gate; these tests pin it — and its combination with
/// `PackingPermissions.canManage` — against an in-memory container with
/// seeded `trip_members`, same shape as `ConfirmationCodeIntentSupportTests`.
final class TripMemberRoleLookupTests: XCTestCase {
    private func makeContext() -> ModelContext {
        ModelContext(AppSchema.makeContainer(inMemory: true))
    }

    private func seedMember(_ context: ModelContext, tripId: UUID, userId: UUID, role: TripRole) {
        context.insert(TripMember(id: UUID(), tripId: tripId, userId: userId, roleRaw: role.rawValue, createdAt: .now))
    }

    func testOrganizerIsFoundAndAllowedToManage() throws {
        let context = makeContext()
        let tripId = UUID()
        let userId = UUID()
        seedMember(context, tripId: tripId, userId: userId, role: .organizer)
        try context.save()

        let role = TripMemberRoleLookup.role(forUserId: userId, tripId: tripId, in: context)

        XCTAssertEqual(role, .organizer)
        XCTAssertTrue(PackingPermissions.canManage(role: role))
    }

    func testCompanionIsFoundAndAllowedToManage() throws {
        let context = makeContext()
        let tripId = UUID()
        let userId = UUID()
        seedMember(context, tripId: tripId, userId: userId, role: .companion)
        try context.save()

        let role = TripMemberRoleLookup.role(forUserId: userId, tripId: tripId, in: context)

        XCTAssertEqual(role, .companion)
        XCTAssertTrue(PackingPermissions.canManage(role: role))
    }

    func testViewerIsFoundAndRefused() throws {
        let context = makeContext()
        let tripId = UUID()
        let userId = UUID()
        seedMember(context, tripId: tripId, userId: userId, role: .viewer)
        try context.save()

        let role = TripMemberRoleLookup.role(forUserId: userId, tripId: tripId, in: context)

        XCTAssertEqual(role, .viewer)
        XCTAssertFalse(PackingPermissions.canManage(role: role))
    }

    /// No membership row for this user on this trip at all (never joined, or
    /// mid-first-pull) — reads `nil`, same as `PackingListView.myRole`, and
    /// `PackingPermissions.canManage(role: nil)` already denies it with no
    /// extra handling needed.
    func testUnknownMembershipReturnsNilAndIsRefused() throws {
        let context = makeContext()
        let tripId = UUID()
        // A member row for a DIFFERENT user on this trip must not leak in.
        seedMember(context, tripId: tripId, userId: UUID(), role: .organizer)
        try context.save()

        let role = TripMemberRoleLookup.role(forUserId: UUID(), tripId: tripId, in: context)

        XCTAssertNil(role)
        XCTAssertFalse(PackingPermissions.canManage(role: role))
    }

    /// `trip_members` scopes role per trip, not per account — this user's
    /// organizer role on one trip must never leak into a lookup for another.
    func testMembershipOnADifferentTripDoesNotLeakIn() throws {
        let context = makeContext()
        let userId = UUID()
        seedMember(context, tripId: UUID(), userId: userId, role: .organizer)
        try context.save()

        XCTAssertNil(TripMemberRoleLookup.role(forUserId: userId, tripId: UUID(), in: context))
    }
}
