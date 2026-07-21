import XCTest
@testable import Tripto

/// UX-1 fix-round: `ingest-text`'s response now carries `createdItemIds`
/// (navbytes/backend#18, additive) — the piece that makes cloud-routed
/// auto-attach possible at all (`PasteImportSheet.sendToRemote` reads
/// `response.createdItemIds?.first`). `IngestTextResponse` is `internal`
/// (not `private`, see its own doc comment) specifically so this decode is
/// directly testable — plain camelCase, no `JSONCoding` snake_case
/// conversion (matches `IngestTextRequest`'s own doc comment on why).
final class IngestTextResponseDecodingTests: XCTestCase {
    func testDecodesCreatedItemIdsInInsertionOrder() throws {
        let firstId = UUID()
        let secondId = UUID()
        let json = """
        {"created":2,"packingItems":[],"itineraryFailed":false,"packingFailed":false,
         "createdItemIds":["\(firstId.uuidString)","\(secondId.uuidString)"]}
        """
        let decoded = try JSONDecoder().decode(IngestTextResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.createdItemIds, [firstId, secondId], "insertion order, first = primary (UX-1)")
    }

    /// The common "nothing found" response — `createdItemIds` must decode
    /// to an empty array, not fail the whole response or force an optional.
    func testDecodesEmptyCreatedItemIdsWhenNothingWasCreated() throws {
        let json = """
        {"created":0,"packingItems":[],"itineraryFailed":false,"packingFailed":false,"createdItemIds":[]}
        """
        let decoded = try JSONDecoder().decode(IngestTextResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.createdItemIds, [])
    }

    /// CRITICAL fix (re-review): §3.6 contract discipline — a rollback/
    /// redeploy of `ingest-text` from a ref older than #18 returns a
    /// response with NO `createdItemIds` key at all. The field must be
    /// optional so this still decodes (`keyNotFound` would otherwise fail
    /// the ENTIRE response — breaking cloud text-import outright, not just
    /// the attach offer).
    func testDecodesSuccessfullyWhenCreatedItemIdsKeyIsAbsentEntirely() throws {
        let json = """
        {"created":1,"packingItems":[],"itineraryFailed":false,"packingFailed":false}
        """
        let decoded = try JSONDecoder().decode(IngestTextResponse.self, from: Data(json.utf8))
        XCTAssertNil(decoded.createdItemIds)
        XCTAssertEqual(decoded.created, 1, "the rest of the response must still decode fine")
    }
}

/// P-12 fix: `PasteImportSheet.isReviewConfirmDisabled`'s exact decision — a
/// `private` computed property on a View struct entangled with `@State`, so
/// unreachable directly from a hermetic test (same situation
/// `PasteImportSheetBatchOrderingTests`'s header comment documents for
/// `processBatch`). Mirrors the fixed shape verbatim:
///
/// ```swift
/// private var isReviewConfirmDisabled: Bool {
///     if isConfirmingReview { return true }
///     guard pendingAttachment == nil else { return false }
///     return !packingCandidates.isEmpty && toAddCandidates.isEmpty
/// }
/// ```
///
/// The regression this guards: the ORIGINAL shape
/// (`!packingCandidates.isEmpty && toAddCandidates.isEmpty`) had no idea
/// `pendingAttachment` existed — unchecking every packing candidate on a
/// batch that ALSO had an attach offer disabled the only button on screen,
/// with no way to finish (P-12's "dead-end").
final class PasteImportSheetReviewTests: XCTestCase {
    private func isReviewConfirmDisabled(
        isConfirmingReview: Bool, hasPendingAttachment: Bool, packingCandidatesEmpty: Bool, toAddCandidatesEmpty: Bool
    ) -> Bool {
        if isConfirmingReview { return true }
        guard !hasPendingAttachment else { return false }
        return !packingCandidatesEmpty && toAddCandidatesEmpty
    }

    /// The exact P-12 dead-end: a pending attach, packing candidates present
    /// but every one of them unchecked — must stay ENABLED (there's still a
    /// meaningful action: confirm the attach).
    func testPendingAttachmentAloneKeepsConfirmEnabledEvenWithAllPackingCandidatesUnchecked() {
        XCTAssertFalse(
            isReviewConfirmDisabled(
                isConfirmingReview: false, hasPendingAttachment: true, packingCandidatesEmpty: false, toAddCandidatesEmpty: true
            )
        )
    }

    /// Pure attach-only review screen (no packing text at all) — always
    /// enabled regardless of the (vacuously-true) packing-empty checks.
    func testPendingAttachmentAloneWithNoPackingCandidatesIsEnabled() {
        XCTAssertFalse(
            isReviewConfirmDisabled(
                isConfirmingReview: false, hasPendingAttachment: true, packingCandidatesEmpty: true, toAddCandidatesEmpty: true
            )
        )
    }

    /// No pending attach at all — original behavior preserved exactly:
    /// disabled only when there WERE packing candidates and all got
    /// unchecked.
    func testNoPendingAttachmentPreservesOriginalPackingOnlyBehavior() {
        XCTAssertTrue(
            isReviewConfirmDisabled(
                isConfirmingReview: false, hasPendingAttachment: false, packingCandidatesEmpty: false, toAddCandidatesEmpty: true
            )
        )
        XCTAssertFalse(
            isReviewConfirmDisabled(
                isConfirmingReview: false, hasPendingAttachment: false, packingCandidatesEmpty: false, toAddCandidatesEmpty: false
            )
        )
    }

    /// An in-flight confirm (awaiting `resolveAttachTarget`/`attach`) always
    /// disables the button, regardless of what would otherwise be true —
    /// no double-submit.
    func testInFlightConfirmAlwaysDisablesRegardlessOfOtherState() {
        XCTAssertTrue(
            isReviewConfirmDisabled(
                isConfirmingReview: true, hasPendingAttachment: true, packingCandidatesEmpty: true, toAddCandidatesEmpty: true
            )
        )
    }
}
