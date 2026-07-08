import XCTest
@testable import Tripto

/// Packing progress math + empty-group hiding (this milestone's brief §5) —
/// `PackingProgress`/`PackingGrouping` pure logic behind `PackingListView`,
/// plus `PackingPermissions`' live-RLS-mirroring rules.
final class PackingProgressTests: XCTestCase {
    private func makeItem(
        label: String = "Item", group: PackingGroupKey = .shared, isDone: Bool = false,
        assignee: UUID? = nil, createdBy: UUID = UUID()
    ) -> PackingItem {
        PackingItem(
            id: UUID(), tripId: UUID(), label: label, groupKeyRaw: group.rawValue,
            assigneeProfileId: assignee, isDone: isDone, createdBy: createdBy,
            createdAt: .now, updatedAt: .now, updatedBy: nil
        )
    }

    // MARK: - Progress math

    func testSummaryCountsDoneAndTotal() {
        let items = [makeItem(isDone: true), makeItem(isDone: true), makeItem(isDone: false)]
        let summary = PackingProgress.summary(for: items)
        XCTAssertEqual(summary.done, 2)
        XCTAssertEqual(summary.total, 3)
    }

    func testPercentRoundsToNearestWholeNumber() {
        // 1 of 3 = 33.33...% -> rounds to 33.
        let summary = PackingProgress.Summary(done: 1, total: 3)
        XCTAssertEqual(summary.percent, 33)
    }

    func testPercentIsZeroForAnEmptyListNotNaN() {
        let summary = PackingProgress.Summary(done: 0, total: 0)
        XCTAssertEqual(summary.percent, 0)
    }

    func testPercentIsHundredWhenFullyPacked() {
        let items = [makeItem(isDone: true), makeItem(isDone: true)]
        XCTAssertEqual(PackingProgress.summary(for: items).percent, 100)
    }

    // MARK: - Grouping / empty-group hiding

    func testGroupsOmitsEmptyGroupsEntirely() {
        let items = [makeItem(group: .documents), makeItem(group: .kids)]
        let groups = PackingGrouping.groups(for: items)
        XCTAssertEqual(groups.map(\.key), [.documents, .kids], "shared/clothing/custom have no items and must not appear")
    }

    func testGroupsFollowTheFixedDisplayOrderRegardlessOfInputOrder() {
        let items = [makeItem(group: .custom), makeItem(group: .documents), makeItem(group: .shared)]
        let groups = PackingGrouping.groups(for: items)
        XCTAssertEqual(groups.map(\.key), [.documents, .shared, .custom])
    }

    func testGroupsWithNoItemsAtAllReturnsEmpty() {
        XCTAssertTrue(PackingGrouping.groups(for: []).isEmpty)
    }

    func testEachGroupContainsOnlyItsOwnItems() {
        let doc = makeItem(label: "Passport", group: .documents)
        let kid = makeItem(label: "Car seat", group: .kids)
        let groups = PackingGrouping.groups(for: [doc, kid])
        XCTAssertEqual(groups.first { $0.key == .documents }?.items.map(\.label), ["Passport"])
        XCTAssertEqual(groups.first { $0.key == .kids }?.items.map(\.label), ["Car seat"])
    }

    func testAllFiveGroupsCanBeNonEmptySimultaneously() {
        let items = PackingGroupKey.allCases.map { makeItem(group: $0) }
        let groups = PackingGrouping.groups(for: items)
        XCTAssertEqual(groups.map(\.key), PackingGrouping.order)
    }

    // MARK: - PackingPermissions (live RLS: packing_items_insert/_update/_delete)

    func testCanManageIsOrganizerOrCompanionOnly() {
        XCTAssertTrue(PackingPermissions.canManage(role: .organizer))
        XCTAssertTrue(PackingPermissions.canManage(role: .companion))
        XCTAssertFalse(PackingPermissions.canManage(role: .viewer))
        XCTAssertFalse(PackingPermissions.canManage(role: nil))
    }

    func testCanDeleteAllowsOrganizerRegardlessOfCreator() {
        let item = makeItem(createdBy: UUID())
        XCTAssertTrue(PackingPermissions.canDelete(item: item, role: .organizer, userId: UUID()))
    }

    /// Matches the live `packing_items_delete` policy literally
    /// (`created_by = auth.uid()` carries no role check of its own) — see
    /// `PackingPermissions.canDelete`'s doc comment.
    func testCanDeleteAllowsTheCreatorEvenIfNoLongerCompanion() {
        let creator = UUID()
        let item = makeItem(createdBy: creator)
        XCTAssertTrue(PackingPermissions.canDelete(item: item, role: .viewer, userId: creator))
    }

    func testCanDeleteDeniesACompanionWhoDidNotCreateIt() {
        let item = makeItem(createdBy: UUID())
        XCTAssertFalse(PackingPermissions.canDelete(item: item, role: .companion, userId: UUID()))
    }

    func testCanDeleteDeniesWithNoUserId() {
        let item = makeItem(createdBy: UUID())
        XCTAssertFalse(PackingPermissions.canDelete(item: item, role: .companion, userId: nil))
    }
}
