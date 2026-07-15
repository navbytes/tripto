import SwiftData
import XCTest
@testable import Tripto

/// P6.3 (docs/UX_REDESIGN_ROADMAP.md): `ProfileDedupe`'s pairing/
/// normalization (pure) and its SwiftData merge (re-points
/// `item_assignees`/packing, deletes the duplicate `trip_profiles` row) —
/// same hermetic, in-memory-container shape as `HomeDuplicationTests`/
/// `TripMergeTests`.
final class ProfileDedupeTests: XCTestCase {
    private func profile(tripId: UUID, name: String, createdAt: Date = .now) -> TripProfile {
        TripProfile(id: UUID(), tripId: tripId, displayName: name, avatarColor: "amber", linkedUserId: nil, createdAt: createdAt)
    }

    // MARK: - duplicatePairs / normalizedKey

    func testProfilesSharingANormalizedNameArePaired() {
        let tripId = UUID()
        let older = profile(tripId: tripId, name: "Mom", createdAt: Date(timeIntervalSince1970: 0))
        let newer = profile(tripId: tripId, name: "  MOM ", createdAt: Date(timeIntervalSince1970: 100))

        let pairs = ProfileDedupe.duplicatePairs(in: [newer, older])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.survivor.id, older.id, "the earlier-created profile survives by default")
        XCTAssertEqual(pairs.first?.duplicate.id, newer.id)
    }

    /// D1: survivor tie-break is `createdAt` then `id` (matches
    /// `HomeTripOrdering.ahead`'s own compound-key discipline) — two rows
    /// written in the exact same instant (e.g. a bulk import) must still
    /// resolve deterministically, not depend on `Dictionary`-grouping order.
    func testEqualCreatedAtBreaksTheSurvivorTieByIdAscending() {
        let tripId = UUID()
        let same = Date(timeIntervalSince1970: 0)
        let a = profile(tripId: tripId, name: "Sam", createdAt: same)
        let b = profile(tripId: tripId, name: "Sam", createdAt: same)
        let expectedSurvivor = [a, b].min { $0.id.uuidString < $1.id.uuidString }!

        let forward = ProfileDedupe.duplicatePairs(in: [a, b])
        let reversed = ProfileDedupe.duplicatePairs(in: [b, a])
        XCTAssertEqual(forward.first?.survivor.id, expectedSurvivor.id)
        XCTAssertEqual(reversed.first?.survivor.id, expectedSurvivor.id, "input order must not change which profile survives")
    }

    func testDifferentNamesAreNeverPaired() {
        let tripId = UUID()
        let a = profile(tripId: tripId, name: "Mom")
        let b = profile(tripId: tripId, name: "Dad")
        XCTAssertTrue(ProfileDedupe.duplicatePairs(in: [a, b]).isEmpty)
    }

    /// Blank names never group together — an empty key would otherwise
    /// pair every no-name profile on a trip.
    func testBlankNamesAreNeverPaired() {
        let tripId = UUID()
        let a = profile(tripId: tripId, name: "")
        let b = profile(tripId: tripId, name: "   ")
        XCTAssertTrue(ProfileDedupe.duplicatePairs(in: [a, b]).isEmpty)
    }

    /// A 3-way tie all pairs against the SAME (earliest) survivor rather
    /// than chaining — distinct from `TripMergeDetection`'s adjacent-chain
    /// rule, since profiles have no "adjacent in a sorted list" concept.
    func testThreeProfilesSharingANameAllPairAgainstTheSameEarliestSurvivor() {
        let tripId = UUID()
        let earliest = profile(tripId: tripId, name: "Sam", createdAt: Date(timeIntervalSince1970: 0))
        let middle = profile(tripId: tripId, name: "Sam", createdAt: Date(timeIntervalSince1970: 100))
        let latest = profile(tripId: tripId, name: "Sam", createdAt: Date(timeIntervalSince1970: 200))

        let pairs = ProfileDedupe.duplicatePairs(in: [latest, earliest, middle])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.allSatisfy { $0.survivor.id == earliest.id })
        XCTAssertEqual(Set(pairs.map(\.duplicate.id)), Set([middle.id, latest.id]))
    }

    func testEmptyAndSingleProfileListsHaveNoPairs() {
        XCTAssertTrue(ProfileDedupe.duplicatePairs(in: []).isEmpty)
        XCTAssertTrue(ProfileDedupe.duplicatePairs(in: [profile(tripId: UUID(), name: "Sam")]).isEmpty)
    }

    /// `normalizedKey`'s own doc comment is explicit: "trimmed + lowercased"
    /// — no diacritic folding. Pins that actual, as-documented behavior
    /// rather than assuming Unicode-savvy matching: "José" and "Jose" are
    /// two different normalized keys today, so they are NOT offered as a
    /// dedupe pair. Flagging in the handoff as a product question (the
    /// roadmap only says "normalized name", which doesn't settle this) —
    /// not a code defect, since the implementation matches its own doc
    /// comment exactly.
    func testDiacriticVariantsAreNotConsideredDuplicatesByTheCurrentNormalization() {
        let tripId = UUID()
        let withAccent = profile(tripId: tripId, name: "José")
        let withoutAccent = profile(tripId: tripId, name: "Jose")
        XCTAssertTrue(
            ProfileDedupe.duplicatePairs(in: [withAccent, withoutAccent]).isEmpty,
            "current normalization is trim+lowercase only — accented and unaccented spellings are distinct keys"
        )
    }

    /// Emoji are significant to the match, same as any other character —
    /// `normalizedKey` only trims/lowercases, it never strips symbols.
    /// Identical emoji still pair like any other identical (case-insensitive)
    /// name; adding/removing an emoji changes the string and must not pair.
    func testEmojiIsSignificantToNormalizedMatching() {
        let tripId = UUID()
        let a = profile(tripId: tripId, name: "Mom \u{1F475}")
        let b = profile(tripId: tripId, name: "MOM \u{1F475}")
        XCTAssertEqual(ProfileDedupe.duplicatePairs(in: [a, b]).count, 1, "identical emoji + case-only difference still pairs")

        let plain = profile(tripId: tripId, name: "Mom")
        let withEmoji = profile(tripId: tripId, name: "Mom \u{1F475}")
        XCTAssertTrue(
            ProfileDedupe.duplicatePairs(in: [plain, withEmoji]).isEmpty,
            "an emoji suffix makes the two names genuinely different strings"
        )
    }

    /// D1 FIXED (was an `XCTExpectFailure`-wrapped known gap — security/
    /// reviewer/tester converged on this as a HIGH data-loss risk):
    /// `duplicatePairs` now excludes every `linkedUserId != nil` profile
    /// BEFORE grouping, so a linked profile can never be offered as either
    /// side of a pair — not "the linked one always wins," but "the linked
    /// one is invisible to this function." With only one (unlinked)
    /// profile left, there's nothing to pair it with.
    func testALinkedProfileIsNeverPairedWithAnUnlinkedNamesake() {
        let tripId = UUID()
        let unlinkedOlder = profile(tripId: tripId, name: "Mom", createdAt: Date(timeIntervalSince1970: 0))
        let linkedNewer = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Mom", avatarColor: "amber",
            linkedUserId: UUID(), createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(
            ProfileDedupe.duplicatePairs(in: [unlinkedOlder, linkedNewer]).isEmpty,
            "a linked profile is excluded from detection entirely — the unlinked namesake has no eligible partner left"
        )
    }

    /// D1's other named manifestation: two DISTINCT, both-linked real
    /// account members who happen to share a display name must never be
    /// offered as a dedupe pair either — sharing a name is common (family
    /// members) and is not evidence they're the same person once both sides
    /// are real accounts.
    func testTwoDistinctLinkedProfilesSharingANameAreNeverPaired() {
        let tripId = UUID()
        let linkedA = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Sam", avatarColor: "amber",
            linkedUserId: UUID(), createdAt: Date(timeIntervalSince1970: 0)
        )
        let linkedB = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Sam", avatarColor: "moss",
            linkedUserId: UUID(), createdAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(ProfileDedupe.duplicatePairs(in: [linkedA, linkedB]).isEmpty)
    }

    // MARK: - merge

    @MainActor
    func testMergeRepointsItemAssigneeAndDeletesTheDuplicateProfile() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let tripId = UUID()
        let survivor = profile(tripId: tripId, name: "Mom")
        let duplicate = profile(tripId: tripId, name: "Mom")
        context.insert(survivor)
        context.insert(duplicate)
        let itemId = UUID()
        context.insert(ItemAssignee(itemId: itemId, profileId: duplicate.id))
        try context.save()

        let result = await ProfileDedupe.merge(
            survivorId: survivor.id, duplicateId: duplicate.id, tripId: tripId, modelContext: context, ensureTripLoaded: {}
        )

        XCTAssertEqual(result?.itemIdsToUnassignFromDuplicate, [itemId])
        XCTAssertEqual(result?.itemIdsToAssignToSurvivor, [itemId])

        let assignees = try context.fetch(FetchDescriptor<ItemAssignee>())
        XCTAssertEqual(assignees.count, 1)
        XCTAssertEqual(assignees.first?.profileId, survivor.id)

        let profiles = try context.fetch(FetchDescriptor<TripProfile>())
        XCTAssertEqual(profiles.map(\.id), [survivor.id], "the duplicate profile row is gone")
    }

    /// An item already assigned to BOTH profiles must end up assigned to
    /// the survivor exactly once afterward — inserting a second row for
    /// the same (item, survivor) pair would collide with `ItemAssignee`'s
    /// deterministic composite id.
    @MainActor
    func testAnItemAlreadyAssignedToBothProfilesEndsUpAssignedOnlyOnceToTheSurvivor() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let tripId = UUID()
        let survivor = profile(tripId: tripId, name: "Mom")
        let duplicate = profile(tripId: tripId, name: "Mom")
        context.insert(survivor)
        context.insert(duplicate)
        let itemId = UUID()
        context.insert(ItemAssignee(itemId: itemId, profileId: survivor.id))
        context.insert(ItemAssignee(itemId: itemId, profileId: duplicate.id))
        try context.save()

        let result = await ProfileDedupe.merge(
            survivorId: survivor.id, duplicateId: duplicate.id, tripId: tripId, modelContext: context, ensureTripLoaded: {}
        )

        XCTAssertEqual(result?.itemIdsToUnassignFromDuplicate, [itemId])
        XCTAssertEqual(result?.itemIdsToAssignToSurvivor, [], "already assigned to the survivor — nothing new to write")

        let assignees = try context.fetch(FetchDescriptor<ItemAssignee>())
        XCTAssertEqual(assignees.count, 1, "no duplicate assignee row for the same (item, survivor) pair")
        XCTAssertEqual(assignees.first?.profileId, survivor.id)
    }

    @MainActor
    func testMergeRepointsPackingItemAssignee() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let tripId = UUID()
        let survivor = profile(tripId: tripId, name: "Mom")
        let duplicate = profile(tripId: tripId, name: "Mom")
        context.insert(survivor)
        context.insert(duplicate)
        let packing = PackingItem(
            id: UUID(), tripId: tripId, label: "Sunscreen", groupKeyRaw: PackingGroupKey.shared.rawValue,
            assigneeProfileId: duplicate.id, isDone: false, createdBy: nil, createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        context.insert(packing)
        try context.save()

        let result = await ProfileDedupe.merge(
            survivorId: survivor.id, duplicateId: duplicate.id, tripId: tripId, modelContext: context, ensureTripLoaded: {}
        )

        XCTAssertEqual(result?.repointedPackingItems.map(\.id), [packing.id])
        let onDisk = try XCTUnwrap(try context.fetch(FetchDescriptor<PackingItem>()).first)
        XCTAssertEqual(onDisk.assigneeProfileId, survivor.id)
    }

    /// `nil` (a genuine failure the caller must surface), not a silent
    /// no-op success, when the duplicate profile no longer exists locally —
    /// same "nil means it actually failed" contract `TripMerge.execute`/
    /// `HomeDuplication.cloneContent` already use.
    @MainActor
    func testMergeReturnsNilWhenTheDuplicateProfileNoLongerExistsLocally() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let result = await ProfileDedupe.merge(
            survivorId: UUID(), duplicateId: UUID(), tripId: UUID(), modelContext: context, ensureTripLoaded: {}
        )
        XCTAssertNil(result)
    }

    /// D1 defense in depth: `merge` itself refuses to delete a linked
    /// profile, independent of `duplicatePairs`'s own exclusion — a second,
    /// cheap guard directly at the destructive mutation so no future caller
    /// bypassing `duplicatePairs` could still delete a real account member.
    @MainActor
    func testMergeRefusesToDeleteALinkedDuplicateProfile() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let tripId = UUID()
        let survivor = profile(tripId: tripId, name: "Mom")
        let linkedDuplicate = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Mom", avatarColor: "moss",
            linkedUserId: UUID(), createdAt: .now
        )
        context.insert(survivor)
        context.insert(linkedDuplicate)
        try context.save()

        let result = await ProfileDedupe.merge(
            survivorId: survivor.id, duplicateId: linkedDuplicate.id, tripId: tripId, modelContext: context, ensureTripLoaded: {}
        )

        XCTAssertNil(result, "merge must refuse a linked profile even if asked directly")
        let profiles = try context.fetch(FetchDescriptor<TripProfile>())
        XCTAssertEqual(profiles.count, 2, "nothing was deleted")
    }
}
