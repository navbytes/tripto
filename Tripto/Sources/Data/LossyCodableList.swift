import Foundation

/// A JSON array that decodes leniently: PostgREST returns every pull result
/// as a plain array of rows, and Swift's synthesized `Array<T: Decodable>`
/// conformance aborts the *entire* array the moment a single element fails
/// to decode (a narrowed column, an unexpected null, a value outside a
/// `String`-backed enum's known cases). That turns one malformed server row
/// into a blank/stale Home or trip screen (SYNC_DESIGN.md pull-apply
/// contract: a pull should degrade gracefully, not throw wholesale).
///
/// `SyncEngine+Pull.swift`'s pull methods decode every DTO array through
/// this instead of `[T]` directly, then pass both `.elements` and
/// `.skippedCount` on to the matching `SyncStore.applyX` — a bad row is
/// dropped from `.elements` (and logged) rather than sinking its siblings,
/// and `.skippedCount` tells `SyncStore` when "absent from this pull" might
/// just mean "failed to decode this time," not "deleted server-side" (D1).
///
/// Never logs a skipped row's fields, only its DTO type and position in the
/// array — a row may carry a `confirmation` code or other data BUILD_PLAN
/// §7.5 says never to log.
struct LossyCodableList<Element: Decodable & Sendable>: Decodable, Sendable {
    let elements: [Element]
    /// How many rows this decode dropped — `SyncStore`'s applyX methods use
    /// this to skip the whole delete phase for a table whenever it's
    /// nonzero (D1: a row that only failed tolerant decode this pull must
    /// never be mistaken for one the server actually deleted).
    let skippedCount: Int

    init(elements: [Element], skippedCount: Int = 0) {
        self.elements = elements
        self.skippedCount = skippedCount
    }

    /// Decodes `Element` inside its own single-value container so a failure
    /// is caught *before* it can escape to the outer unkeyed container —
    /// the outer `container.decode(Wrapped.self)` call in `init(from:)`
    /// below therefore always succeeds, and its cursor reliably advances
    /// past the bad element. (A bare `try? container.decode(Element.self)`
    /// loop doesn't have this property: a thrown error can leave the
    /// unkeyed container's cursor exactly where it failed, re-decoding the
    /// same element forever.)
    private struct Wrapped: Decodable {
        let element: Element?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            element = try? container.decode(Element.self)
        }
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skippedCount = 0
        var index = 0
        while !container.isAtEnd {
            if let element = try container.decode(Wrapped.self).element {
                elements.append(element)
            } else {
                skippedCount += 1
                logDebug("LossyCodableList<\(Element.self)>: skipped malformed row at index \(index)")
            }
            index += 1
        }
        self.elements = elements
        self.skippedCount = skippedCount
    }
}
