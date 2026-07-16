import Foundation

/// The one JSON coding mechanism used for every DTO in the app: snake_case
/// keys (via `.convertToSnakeCase`/`.convertFromSnakeCase`, so DTOs are
/// plain camelCase Swift structs with no per-field `CodingKeys`) and a
/// fractional-seconds-tolerant ISO8601 date strategy.
///
/// Used in three places, deliberately kept identical everywhere so there is
/// exactly one date/casing behavior in the app (M1 deliverable: "pick ONE
/// mechanism and use it consistently"):
/// 1. `Supa.client`'s PostgREST `db.encoder`/`db.decoder` (Data/SupabaseClient.swift)
///    — every network request/response body.
/// 2. `OutboxOp.payloadJSON` — the snapshot stored for a queued push.
/// 3. Local round-trips in tests.
enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.withFractionalSeconds.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601.withFractionalSeconds.date(from: raw) {
                return date
            }
            if let date = ISO8601.withoutFractionalSeconds.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(raw)"
            )
        }
        return decoder
    }()

    /// Structural passthrough — no key conversion, still the same
    /// fractional-seconds-tolerant date handling.
    ///
    /// Deliberately separate from `decoder` above: `.convertFromSnakeCase`
    /// rewrites the keys of *every* keyed container it walks through,
    /// including a plain `[String: AnyJSON]` dictionary decoded via
    /// `AnyJSON`'s `.object` case — not just a DTO's `CodingKeys`. Anywhere
    /// this app decodes already-final JSON into a structural `AnyJSON`
    /// value (an outbox op's stored payload on its way back out to
    /// PostgREST; an `itinerary_items.details` blob), the keys must survive
    /// byte-for-byte — PostgREST needs the literal column name `trip_id`,
    /// not a re-mangled `tripId`. Use this decoder for that; use `decoder`
    /// above only when decoding into a real DTO whose keys are meant to be
    /// derived from Swift property names.
    static let passthroughDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONCoding.decoder.dateDecodingStrategy
        return decoder
    }()

    /// Encode-side counterpart of `passthroughDecoder`, for symmetry and for
    /// any future arbitrary-JSON value this app builds up in code (rather
    /// than passing through verbatim) before sending it out. `.object`'s
    /// keys are already whatever they need to be; snake-casing is a no-op
    /// on keys that are already snake_case, but isn't guaranteed to be for
    /// arbitrary opaque content, so this avoids the assumption entirely.
    static let passthroughEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONCoding.encoder.dateEncodingStrategy
        return encoder
    }()
}
