import Foundation

// Pure, model-free half of "Suggest a starting list" (PLAN.md ai-garnish) —
// sibling to `ImportExtraction.swift`'s own split: `Platform/
// OnDeviceExtractor.swift`'s `suggestPacking` produces `[RawExtractedPackingItem]`,
// and everything below turns that into vettable `PackingCandidate` rows
// (`Design/Components/PackingCandidateRow.swift`) with no FoundationModels
// dependency, so it's hermetically testable with no live model.
enum PackingSuggestions {
    /// Reuses `ImportExtraction.mapPackingItem`'s exact label-trim/
    /// group-whitelist rule (DRY) — a suggested item is validated exactly
    /// like an extracted-from-paste one, then wrapped as a pre-checked
    /// vetting row for `PackingSuggestionsSheet`'s checklist.
    static func candidates(from raw: [RawExtractedPackingItem]) -> [PackingCandidate] {
        raw.compactMap { item in
            ImportExtraction.mapPackingItem(item).map { PackingCandidate(label: $0.label, groupKey: $0.groupKey) }
        }
    }

    /// The real duplicate guard (PLAN.md: "client-side dedupe against
    /// existing labels as the real guard") — the model's own "no
    /// duplicates" instruction is a hint, not an authority; this is what
    /// actually keeps a re-suggested "Passports" off the checklist.
    /// Case/whitespace-insensitive so "passports " and "Passports" both
    /// count as the same existing item.
    static func dedupe(_ candidates: [PackingCandidate], existingLabels: [String]) -> [PackingCandidate] {
        let existing = Set(existingLabels.map(Self.normalized))
        return candidates.filter { !existing.contains(Self.normalized($0.label)) }
    }

    private static func normalized(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
