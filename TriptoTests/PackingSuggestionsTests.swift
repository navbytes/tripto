import XCTest
@testable import Tripto

/// `PackingSuggestions` — the pure, model-free half of "Suggest a starting
/// list" (PLAN.md ai-garnish). `Platform/OnDeviceExtractor.swift`'s own
/// house rule ("do not unit-test actual model calls") is why this file
/// only ever builds `RawExtractedPackingItem`/`PackingCandidate` values by
/// hand — no live session, no mock of Apple's API.
final class PackingSuggestionsTests: XCTestCase {
    // MARK: - candidates(from:) — reuses ImportExtraction.mapPackingItem,
    // so this only proves the wiring, not that rule's own cases (already
    // covered by ImportExtractionTests).

    func testCandidatesTrimsLabelsAndDefaultToChecked() {
        let raw = [RawExtractedPackingItem(label: "  Passports  ", groupKey: "documents")]

        let candidates = PackingSuggestions.candidates(from: raw)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.label, "Passports")
        XCTAssertEqual(candidates.first?.groupKey, .documents)
        XCTAssertEqual(candidates.first?.isChecked, true, "suggestions start pre-checked, same as paste-import's own checklist")
    }

    func testCandidatesDropsBlankLabels() {
        let raw = [RawExtractedPackingItem(label: "   ", groupKey: "documents")]
        XCTAssertTrue(PackingSuggestions.candidates(from: raw).isEmpty)
    }

    func testCandidatesFallsBackUnknownGroupKeyToCustom() {
        let raw = [RawExtractedPackingItem(label: "Umbrella", groupKey: "electronics")]
        XCTAssertEqual(PackingSuggestions.candidates(from: raw).first?.groupKey, .custom)
    }

    // MARK: - dedupe(_:existingLabels:) — the real duplicate guard (PLAN.md:
    // "client-side dedupe against existing labels as the real guard")

    func testDedupeDropsExactLabelMatch() {
        let candidates = [PackingCandidate(label: "Sunscreen", groupKey: .shared)]
        XCTAssertTrue(PackingSuggestions.dedupe(candidates, existingLabels: ["Sunscreen"]).isEmpty)
    }

    func testDedupeIsCaseAndWhitespaceInsensitive() {
        let candidates = [PackingCandidate(label: "  passports ", groupKey: .documents)]
        XCTAssertTrue(PackingSuggestions.dedupe(candidates, existingLabels: ["Passports"]).isEmpty)
    }

    func testDedupeKeepsCandidatesNotAlreadyOnTheList() {
        let candidates = [
            PackingCandidate(label: "Passports", groupKey: .documents),
            PackingCandidate(label: "Beach towel", groupKey: .shared)
        ]

        let deduped = PackingSuggestions.dedupe(candidates, existingLabels: ["Passports"])

        XCTAssertEqual(deduped.map(\.label), ["Beach towel"])
    }

    func testDedupeWithNoExistingLabelsKeepsEveryCandidate() {
        let candidates = [PackingCandidate(label: "Passports", groupKey: .documents)]
        XCTAssertEqual(PackingSuggestions.dedupe(candidates, existingLabels: []).count, 1)
    }
}
