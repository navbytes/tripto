import Foundation

/// PostgREST emits `timestamptz` as ISO8601 with fractional seconds and a
/// colon-separated offset, e.g. `2026-07-08T12:34:56.789+00:00` — but not
/// every row has non-zero fractional seconds, and some paths (our own
/// encoder, or hand-built fixtures) may omit them entirely. Lives in
/// `Platform/Shared` (compiled into both targets, `project.yml`) rather than
/// `Models/JSONCoding.swift` (app-only) so the widget extension's own
/// `TripSnapshot` coder can reference the same formatter instead of
/// declaring its own (DRY L4) — try the fractional-seconds formatter first,
/// then fall back (see `JSONCoding`'s decoder, `Models/JSONCoding.swift`).
public enum ISO8601 {
    public static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
