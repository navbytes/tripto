import XCTest
@testable import Tripto

/// C3 (`.claude/company/release-1.2/PLAN.md`): `PasteImportSheet
/// .processBatch(_:)`'s SEQUENCING shape — "serial processing (one at a
/// time)" with visible per-item progress. Like
/// `PasteImportSheetInsertStampingTests`/`PasteImportSheetFallbackConsentTests`
/// (see their own header comments), `processBatch` is a `private` instance
/// method entangled with `@State`/`@Environment` and live OCR/PDFKit/
/// Supabase/FoundationModels calls, so it can't be invoked directly from a
/// hermetic test. This suite instead mirrors its actual loop shape verbatim
/// against a plain, mockable per-item processor — the same "pin the shape
/// of an unreachable method" convention those two files already establish:
///
/// ```swift
/// for (index, input) in inputs.enumerated() {
///     if consentDeclined { break }
///     batchProgressText = "Reading \(index + 1) of \(inputs.count)…"
///     ... // OCR/extract this ONE input
///     guard let outcome = await processOneBatchText(...) else {
///         consentDeclined = true   // "Not now" on the consent dialog
///         continue
///     }
///     ... // aggregate outcome, loop to the next input
/// }
/// ```
///
/// proving the three properties that shape guarantees: (1) items run ONE AT
/// A TIME, in the order given — a `for` + `await` loop, never a `TaskGroup`;
/// (2) a per-item skip (unreadable OCR / empty extracted text) does NOT stop
/// the batch — later items still run; (3) once cloud consent is declined,
/// every item after that point is never even attempted. A hypothetical edit
/// that swapped this `for` loop for concurrent processing, or dropped the
/// "skip continues" behavior, would compile fine and regress silently
/// without an equivalent edit here — same residual testability gap the two
/// sibling files' own header comments already accept.
final class PasteImportSheetBatchOrderingTests: XCTestCase {
    /// Verbatim mirror of `processBatch`'s loop control flow (see this
    /// file's header comment) — `process` returning `nil` is a declined-
    /// consent stop (`consentDeclined = true; continue`, then the NEXT
    /// iteration's `if consentDeclined { break }` exits); throwing is a
    /// per-item skip (OCR failure / empty text) that still lets the loop
    /// continue to the next input.
    private func runSerially<Item: Equatable>(
        _ inputs: [Item], process: (Item) async throws -> Int?
    ) async -> (visited: [Item], created: [Int]) {
        var visited: [Item] = []
        var created: [Int] = []
        var consentDeclined = false
        for input in inputs {
            if consentDeclined { break }
            visited.append(input) // stands in for `batchProgressText`'s per-item update
            do {
                guard let result = try await process(input) else {
                    consentDeclined = true
                    continue
                }
                created.append(result)
            } catch {
                continue // unreadable OCR / empty text — batch continues
            }
        }
        return (visited, created)
    }

    func testItemsProcessOneAtATimeInTheGivenOrder() async {
        var runOrder: [Int] = []
        let (visited, created) = await runSerially([1, 2, 3]) { item in
            runOrder.append(item) // records the moment THIS item's work actually ran
            return item * 10
        }
        XCTAssertEqual(visited, [1, 2, 3], "every item is visited in the order given")
        XCTAssertEqual(runOrder, [1, 2, 3], "each item's work completes before the next one starts — never reordered/concurrent")
        XCTAssertEqual(created, [10, 20, 30])
    }

    /// Mirrors a batch of 3 where one image OCRs to nothing/fails — this
    /// milestone's brief: "Empty-OCR result → friendly row, batch continues."
    func testASkippedItemDoesNotStopTheBatch() async {
        struct UnreadableImage: Error {}
        let (visited, created) = await runSerially([1, 2, 3]) { item in
            if item == 2 { throw UnreadableImage() }
            return item
        }
        XCTAssertEqual(visited, [1, 2, 3], "the batch reaches every item, including the one after the skip")
        XCTAssertEqual(created, [1, 3], "the skipped item contributes nothing but doesn't block its neighbors")
    }

    /// Mirrors declining the AI-consent dialog mid-batch (this milestone's
    /// brief: consent "fires BEFORE any upload, once per batch") — nothing
    /// after the decline is even attempted.
    func testADeclinedConsentStopsAllRemainingItems() async {
        let (visited, created) = await runSerially([1, 2, 3]) { item in
            item == 2 ? nil : item // mirrors requestCloudConsentIfNeeded() returning false
        }
        XCTAssertEqual(visited, [1, 2], "item 3 is never even attempted once the batch stops")
        XCTAssertEqual(created, [1])
    }

    /// A single-item batch is the common case (one screenshot) — proves the
    /// loop isn't accidentally off-by-one at either boundary.
    func testSingleItemBatchRunsExactlyOnce() async {
        let (visited, created) = await runSerially([42]) { $0 }
        XCTAssertEqual(visited, [42])
        XCTAssertEqual(created, [42])
    }

    func testEmptyBatchVisitsNothing() async {
        let (visited, created) = await runSerially([Int]()) { $0 }
        XCTAssertTrue(visited.isEmpty)
        XCTAssertTrue(created.isEmpty)
    }
}
