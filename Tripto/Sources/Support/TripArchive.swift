import CryptoKit
import Foundation

// Tripto Archive v1 (docs/IMPORT_FORMAT.md, frozen 2026-07-13) — the one
// JSON format for migration import (Settings "Import trips"), data export
// ("Export trips", BACKLOG §E3), and deterministic test seeding.
//
// This file is the pure half: wire (`Archive*`) types, the UUIDv5 id
// scheme, and `TripArchiveMapper` (decode -> validate -> map). Nothing here
// touches SwiftData or `Models/JSONCoding.swift`'s wire coders — this uses
// its own `JSONDecoder`/`JSONEncoder` — so it unit-tests with plain `Data`
// in/`PreparedTrip` out. `TripArchiveImporter`/`TripArchiveExporter` are the
// thin SwiftData-touching halves built on top of this.

// MARK: - UUIDv5 (RFC 4122 §4.3, SHA-1)

/// The deterministic id scheme IMPORT_FORMAT.md §5 requires so re-importing
/// the same archive converges on the same rows instead of duplicating.
/// `Insecure.SHA1` per the frozen spec — "insecure" is only CryptoKit's
/// naming caution (SHA-1 is unfit for anything security-sensitive); RFC 4122
/// itself specifies SHA-1 for v5, and this is a stable-id derivation, not a
/// security control.
enum UUIDv5 {
    static func generate(namespace: UUID, name: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(name.utf8))
        var digestBytes = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))
        digestBytes[6] = (digestBytes[6] & 0x0F) | 0x50 // version 5
        digestBytes[8] = (digestBytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let uuidTuple: uuid_t = (
            digestBytes[0], digestBytes[1], digestBytes[2], digestBytes[3],
            digestBytes[4], digestBytes[5], digestBytes[6], digestBytes[7],
            digestBytes[8], digestBytes[9], digestBytes[10], digestBytes[11],
            digestBytes[12], digestBytes[13], digestBytes[14], digestBytes[15]
        )
        return UUID(uuid: uuidTuple)
    }
}

// MARK: - Envelope constants

enum TripArchiveFormat {
    static let identifier = "tripto-archive"
    static let supportedVersion = 1
    /// IMPORT_FORMAT.md §5's fixed namespace UUID — every derived row id is
    /// `UUIDv5(namespace, name:)` under this one namespace.
    static let namespace = UUID(uuidString: "A0E4A1D6-5C2B-4E7F-8D3A-9B1C0F2E6D48")!
}

/// §1's hard bounds — violating any of these is an atomic failure (nothing
/// imports), unlike a per-trip/per-item skip.
enum TripArchiveBounds {
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxTrips = 200
    static let maxItemsPerTrip = 500
    /// SEC MEDIUM: a conforming archive nests about 4 levels deep
    /// (envelope -> trips -> trip -> items -> item); 64 is generous
    /// headroom while still well short of a parser's recursion ceiling.
    static let maxNestingDepth = 64
    /// SEC LOWs: mapper-level string clamps (untrusted input) — trim, never fail.
    static let maxIdLength = 128
    static let maxTitleLength = 200
    static let maxNotesLength = 2000
}

/// Atomic-failure reasons (§1) — thrown before any SwiftData write happens.
/// Distinct from `TripSkipReason`/`ItemSkipReason` below, which are
/// per-row and reported, not fatal.
enum TripArchiveError: Error, Equatable {
    case invalidJSON
    case wrongFormat
    case unsupportedVersion(Int)
    case fileTooLarge
    case tooManyTrips(Int)
    case tooManyItemsInTrip(tripId: String, count: Int)
    /// SEC MEDIUM: pathological bracket/brace nesting, rejected before
    /// `JSONDecoder` ever sees it (parser stack-overflow risk).
    case tooDeeplyNested
    /// Not a decode/validation failure — the local SwiftData write itself
    /// failed (mirrors `TripFormView.SaveError.writeFailed`).
    case writeFailed
    /// UX#8: distinct from `.invalidJSON` — the file itself couldn't be
    /// opened/read (permissions, picker failure), not "this isn't a valid
    /// archive." Surfaced by `SettingsView`, not thrown by the mapper.
    case unreadableFile

    var message: String {
        switch self {
        case .invalidJSON:
            return "Couldn\u{2019}t read this file \u{2014} it doesn\u{2019}t look like a Tripto Archive."
        case .wrongFormat:
            return "This file isn\u{2019}t a Tripto Archive."
        case .unsupportedVersion(let version):
            return "This archive is version \(version), which this version of Tripto doesn\u{2019}t "
                + "understand yet. Update Tripto and try again."
        case .fileTooLarge:
            return "This file is too large to import (Tripto archives are limited to 5\u{202F}MB)."
        case .tooManyTrips(let count):
            return "This archive has \(count) trips \u{2014} Tripto can import up to "
                + "\(TripArchiveBounds.maxTrips) at a time."
        case .tooManyItemsInTrip(let tripId, let count):
            return "The trip \u{201C}\(tripId)\u{201D} has \(count) items \u{2014} Tripto can import up to "
                + "\(TripArchiveBounds.maxItemsPerTrip) per trip."
        case .tooDeeplyNested:
            return "This file isn\u{2019}t a valid Tripto Archive \u{2014} its structure is too deeply nested."
        case .writeFailed:
            return "Couldn\u{2019}t save the imported trips. Try again."
        case .unreadableFile:
            return "Couldn\u{2019}t open that file \u{2014} check that Tripto has permission to access it and try again."
        }
    }
}

// MARK: - Report (§6)

enum TripSkipReason: Equatable {
    case missingId
    case missingTitle
    case noStartDate
    case cancelled
    case alreadyImported

    var reportText: String {
        switch self {
        case .missingId: return "missing id"
        case .missingTitle: return "missing title"
        case .noStartDate: return "no start date"
        case .cancelled: return "cancelled"
        case .alreadyImported: return "already imported"
        }
    }
}

enum ItemSkipReason: Equatable {
    case missingId
    case unknownCategory
    case noStartTime
    /// D2/H1: the `items[]` element wasn't even a JSON object (`null`, a
    /// bare string/number) — nothing about it could be read at all.
    case unreadable

    var reportText: String {
        switch self {
        case .missingId: return "missing id"
        case .unknownCategory: return "unknown category"
        case .noStartTime: return "no start time"
        case .unreadable: return "unreadable item"
        }
    }
}

struct TripArchiveTripSkip: Equatable {
    var tripId: String
    var title: String
    var reason: TripSkipReason
    /// P6.1 (docs/UX_REDESIGN_ROADMAP.md): the LOCAL trip this archive row
    /// already matches, when `reason == .alreadyImported` — backs the
    /// import-result sheet's "Open trip" recourse so the view never has to
    /// re-derive which of §5's two idempotence rules matched. `nil` for
    /// every other skip reason, and defaulted so every existing call site/
    /// fixture predating this field keeps compiling unchanged (same
    /// purely-additive convention as `ItineraryItemDTO.source`'s doc comment).
    var existingLocalTripId: UUID?
}

struct TripArchiveItemSkip: Equatable {
    var tripId: String
    /// D2/UX#3: the parent trip's own title, so a skip row can name the
    /// trip without showing the raw archive trip id.
    var tripTitle: String
    var itemId: String
    /// D2/UX#3: best-effort item title/category so a skip row identifies
    /// which item, not just the reason — see `TripArchiveMapper`'s
    /// `bestEffortItemLabel`.
    var itemLabel: String
    var reason: ItemSkipReason
}

/// §6's report contents, built by `TripArchiveMapper.map` — everything the
/// Settings import-result UI needs, with no SwiftData/UI dependency.
struct TripArchiveImportReport: Equatable {
    var tripsImported = 0
    var itemsImported = 0
    var profilesImported = 0
    var tripSkips: [TripArchiveTripSkip] = []
    var itemSkips: [TripArchiveItemSkip] = []
    /// §4.1: count of items whose start zone fell through to the device
    /// zone (no explicit `tz`, no resolvable airport).
    var zoneAssumedCount = 0
    /// §2: trips whose top-level `notes` were non-empty and dropped.
    var droppedNotesCount = 0

    /// Drives the Settings result UI's "alert vs. sheet" split — a clean
    /// import needs nothing more than a one-line confirmation.
    var isFullSuccess: Bool {
        tripSkips.isEmpty && itemSkips.isEmpty && zoneAssumedCount == 0 && droppedNotesCount == 0
    }
}

// MARK: - Wire types (§2, §3)

/// Every field below is optional at the wire-type level — even ones §2/§3
/// mark "required" — so a single malformed trip/item can never throw and
/// take down the whole array's decode (untrusted JSON at a trust boundary:
/// one bad row degrades to a reported skip, not an aborted import).
/// Required-ness is enforced as a plain-value check in `TripArchiveMapper`,
/// which is where "missing/invalid -> skipped and reported" actually lives.
struct ArchiveDocument: Codable {
    var format: String
    var version: Int
    var exportedAt: String?
    var trips: [ArchiveTrip]

    enum CodingKeys: String, CodingKey {
        case format, version
        case exportedAt = "exported_at"
        case trips
    }
}

struct ArchiveTrip {
    var id: String?
    var title: String?
    var destination: String?
    var countryCode: String?
    var startDate: String?
    var endDate: String?
    var tripType: String?
    var status: String?
    var cover: String?
    var travellers: [String]?
    var items: [ArchiveItem]
    var notes: String?
    /// D2/H1: count of `items[]` elements that weren't even a JSON object
    /// (`null`, a bare string/number) and so couldn't decode as an
    /// `ArchiveItem` at all — `TripArchiveMapper.map` turns each of these
    /// into a reported `.unreadable` item skip. Not part of the wire
    /// format (no `CodingKeys` case; never encoded) — decode-only
    /// bookkeeping, defaulted so every existing call site keeps compiling.
    var unreadableItemCount: Int = 0
}

struct ArchiveItem {
    var id: String?
    var category: String?
    var title: String?
    var startsAt: String?
    var endsAt: String?
    var tz: String?
    var locationName: String?
    var confirmation: String?
    var notes: String?
    // Flight
    var airline: String?
    var flightNo: String?
    var fromIATA: String?
    var toIATA: String?
    var seat: String?
    var terminal: String?
    var gate: String?
    var arrivalTz: String?
    // Hotel
    var room: String?
    // Activity
    var ticketRef: String?
    // Food
    var partySize: Int?
    var reservationName: String?
    // Transport
    var provider: String?
    var dropoffLocation: String?
    // Activity & food
    var address: String?
}

extension ArchiveTrip: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, title, destination
        case countryCode = "country_code"
        case startDate = "start_date"
        case endDate = "end_date"
        case tripType = "trip_type"
        case status, cover, travellers, items, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenientString(.id)
        title = container.lenientString(.title)
        destination = container.lenientString(.destination)
        countryCode = container.lenientString(.countryCode)
        startDate = container.lenientString(.startDate)
        endDate = container.lenientString(.endDate)
        tripType = container.lenientString(.tripType)
        status = container.lenientString(.status)
        cover = container.lenientString(.cover)
        travellers = container.lenientStringArray(.travellers)
        // H1 fix: decode each `items[]` element independently
        // (`LenientItemSlot`) rather than `[ArchiveItem]` as one throwing
        // unit — a single non-object element (e.g. `null`, a bare string)
        // used to fail the WHOLE array decode, which `try? ... ?? []`
        // then silently turned into zero items for the trip, with no
        // report and no atomic failure. Now only that one slot is lost.
        let slots = (try? container.decodeIfPresent([LenientItemSlot].self, forKey: .items)).flatMap { $0 } ?? []
        items = slots.compactMap(\.item)
        unreadableItemCount = slots.count - items.count
        notes = container.lenientString(.notes)
    }
}

/// H1 fix support: wraps one `items[]` element so a non-object element
/// (where `ArchiveItem.init(from:)`'s own `decoder.container(keyedBy:)`
/// would throw) degrades to `item == nil` instead of failing the
/// enclosing array decode. `ArchiveItem.init(from:)` is otherwise already
/// non-throwing in practice (its own fields are all lenient), so the only
/// realistic failure this catches is "not even a JSON object".
private struct LenientItemSlot: Decodable {
    let item: ArchiveItem?
    init(from decoder: Decoder) throws {
        item = try? ArchiveItem(from: decoder)
    }
}

extension ArchiveTrip: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encodeIfPresent(countryCode, forKey: .countryCode)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(tripType, forKey: .tripType)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(cover, forKey: .cover)
        try container.encodeIfPresent(travellers, forKey: .travellers)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

extension ArchiveItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, category, title
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case tz
        case locationName = "location_name"
        case confirmation, notes, airline
        case flightNo = "flight_no"
        case fromIATA = "from_iata"
        case toIATA = "to_iata"
        case seat, terminal, gate
        case arrivalTz = "arrival_tz"
        case room
        case ticketRef = "ticket_ref"
        case partySize = "party_size"
        case reservationName = "reservation_name"
        case provider
        case dropoffLocation = "dropoff_location"
        case address
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenientString(.id)
        category = container.lenientString(.category)
        title = container.lenientString(.title)
        startsAt = container.lenientString(.startsAt)
        endsAt = container.lenientString(.endsAt)
        tz = container.lenientString(.tz)
        locationName = container.lenientString(.locationName)
        confirmation = container.lenientString(.confirmation)
        notes = container.lenientString(.notes)
        airline = container.lenientString(.airline)
        flightNo = container.lenientString(.flightNo)
        fromIATA = container.lenientString(.fromIATA)
        toIATA = container.lenientString(.toIATA)
        seat = container.lenientString(.seat)
        terminal = container.lenientString(.terminal)
        gate = container.lenientString(.gate)
        arrivalTz = container.lenientString(.arrivalTz)
        room = container.lenientString(.room)
        ticketRef = container.lenientString(.ticketRef)
        partySize = container.lenientInt(.partySize)
        reservationName = container.lenientString(.reservationName)
        provider = container.lenientString(.provider)
        dropoffLocation = container.lenientString(.dropoffLocation)
        address = container.lenientString(.address)
    }
}

extension ArchiveItem: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(startsAt, forKey: .startsAt)
        try container.encodeIfPresent(endsAt, forKey: .endsAt)
        try container.encodeIfPresent(tz, forKey: .tz)
        try container.encodeIfPresent(locationName, forKey: .locationName)
        try container.encodeIfPresent(confirmation, forKey: .confirmation)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(airline, forKey: .airline)
        try container.encodeIfPresent(flightNo, forKey: .flightNo)
        try container.encodeIfPresent(fromIATA, forKey: .fromIATA)
        try container.encodeIfPresent(toIATA, forKey: .toIATA)
        try container.encodeIfPresent(seat, forKey: .seat)
        try container.encodeIfPresent(terminal, forKey: .terminal)
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encodeIfPresent(arrivalTz, forKey: .arrivalTz)
        try container.encodeIfPresent(room, forKey: .room)
        try container.encodeIfPresent(ticketRef, forKey: .ticketRef)
        try container.encodeIfPresent(partySize, forKey: .partySize)
        try container.encodeIfPresent(reservationName, forKey: .reservationName)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(dropoffLocation, forKey: .dropoffLocation)
        try container.encodeIfPresent(address, forKey: .address)
    }
}

/// Tolerant field access for `ArchiveTrip`/`ArchiveItem`'s custom decode: a
/// missing key OR a key present with the wrong JSON type both resolve to
/// `nil` instead of throwing — only a structurally-broken element (not even
/// a JSON object) still throws, which is fair to treat as "file fails to
/// decode" (§1).
private extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        // `try?` on a throwing, already-`Optional`-returning call flattens
        // to a single level (SE-0230) — one `if let` is enough.
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        // Defensive: tolerate a bare number where a string was expected
        // (e.g. a hand-authored `"id": 42`) rather than losing the row.
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func lenientStringArray(_ key: Key) -> [String]? {
        (try? decodeIfPresent([String].self, forKey: key)).flatMap { $0 }
    }
}

// MARK: - Prepared (validated, insertable) shapes

struct PreparedTripProfile: Equatable {
    var id: UUID
    var displayName: String
    var avatarColor: String
}

struct PreparedTripItem: Equatable {
    var id: UUID
    var category: ItemCategory
    var title: String
    var startsAt: Date
    var endsAt: Date?
    var tz: String
    var locationName: String
    var confirmation: String?
    var notes: String?
    var details: ItemDetails
}

struct PreparedTrip: Equatable {
    var id: UUID
    var title: String
    var destination: String
    var countryCode: String
    var startDate: DayDate
    var endDate: DayDate
    var tripType: TripType
    var coverGradient: String
    var profiles: [PreparedTripProfile]
    var items: [PreparedTripItem]
}

// MARK: - Decode + validate + map

enum TripArchiveMapper {
    private static let decoder = JSONDecoder()

    /// §1: decode (bounded, strict on the envelope) — throws
    /// `TripArchiveError` for anything that should abort the whole import.
    static func decode(_ data: Data) throws -> ArchiveDocument {
        guard data.count <= TripArchiveBounds.maxFileBytes else { throw TripArchiveError.fileTooLarge }
        // SEC MEDIUM: a recursive-descent JSON parser can stack-overflow
        // (uncatchable fatal signal, not a throw) on pathologically deep
        // nesting well within the 5MB cap — pre-scan bracket/brace depth
        // BEFORE handing untrusted bytes to `JSONDecoder`.
        guard !exceedsMaxNestingDepth(data, limit: TripArchiveBounds.maxNestingDepth) else {
            throw TripArchiveError.tooDeeplyNested
        }
        let document: ArchiveDocument
        do {
            document = try decoder.decode(ArchiveDocument.self, from: data)
        } catch {
            throw TripArchiveError.invalidJSON
        }
        guard document.format == TripArchiveFormat.identifier else { throw TripArchiveError.wrongFormat }
        guard document.version == TripArchiveFormat.supportedVersion else {
            throw TripArchiveError.unsupportedVersion(document.version)
        }
        guard document.trips.count <= TripArchiveBounds.maxTrips else {
            throw TripArchiveError.tooManyTrips(document.trips.count)
        }
        for trip in document.trips where trip.items.count > TripArchiveBounds.maxItemsPerTrip {
            throw TripArchiveError.tooManyItemsInTrip(tripId: trip.id ?? "", count: trip.items.count)
        }
        return document
    }

    /// Single-pass byte scan for the max `{`/`[` nesting depth, skipping
    /// characters inside JSON string literals (so a notes field's prose
    /// full of `{}` can't false-positive) — bails the moment the limit is
    /// exceeded, so a malicious deeply-nested file is rejected fast rather
    /// than scanned to the end. Byte-level (not `Character`) is safe here:
    /// every UTF-8 continuation/lead byte for a non-ASCII scalar is >= 0x80,
    /// so it can never alias `{`, `}`, `[`, `]`, `"`, or `\`.
    private static func exceedsMaxNestingDepth(_ data: Data, limit: Int) -> Bool {
        var depth = 0
        var inString = false
        var isEscaped = false
        for byte in data {
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth > limit { return true }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
        return false
    }

    /// §2-§5: maps a validated document into insertable rows + the §6
    /// report. `existingTripIds` are the local `Trip.id`s already in the
    /// store — used two ways per §5's amended idempotence rule:
    /// (a) the derived UUIDv5 already exists locally, or (b) the archive's
    /// own `id` string parses as a UUID that itself matches a local trip
    /// (rule (b) is what makes importing your own export a first-pass
    /// no-op — export writes row UUIDs as archive ids, §7, and UUIDv5
    /// derivation has no fixed points, so rule (a) alone can't catch it).
    /// `deviceTimeZone` is injectable so zone fallback is testable without
    /// depending on the test machine's zone.
    static func map(
        document: ArchiveDocument,
        existingTripIds: Set<UUID>,
        deviceTimeZone: TimeZone = .current
    ) -> (trips: [PreparedTrip], report: TripArchiveImportReport) {
        var prepared: [PreparedTrip] = []
        var report = TripArchiveImportReport()
        // Defensive: a malformed archive repeating the same trip `id` would
        // otherwise derive the same UUIDv5 twice and violate `Trip.id`'s
        // unique constraint at save time, failing the ENTIRE batch (not
        // just that one trip) — untrusted input, so dedupe up front rather
        // than let SwiftData discover it.
        var seenTripUUIDs: Set<UUID> = []

        for (index, rawTrip) in document.trips.enumerated() {
            guard let tripIdStringRaw = nonEmpty(rawTrip.id) else {
                let title = clamp(rawTrip.title ?? "", maxLength: TripArchiveBounds.maxTitleLength)
                report.tripSkips.append(.init(tripId: "", title: title, reason: .missingId))
                continue
            }
            // SEC LOW: clamp before it's ever hashed/stored/displayed.
            let tripIdString = clamp(tripIdStringRaw, maxLength: TripArchiveBounds.maxIdLength)
            let tripUUID = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:\(tripIdString)")
            let displayTitle = clamp(
                rawTrip.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", maxLength: TripArchiveBounds.maxTitleLength
            )
            // §5 rule (b): the archive's raw id, taken at face value as a
            // UUID, already matching a local trip.
            let matchesLocalTripByRawId = UUID(uuidString: tripIdString).map(existingTripIds.contains) ?? false

            // L6 fix: only CHECK `seenTripUUIDs` here (don't insert yet) —
            // inserting happens below, only once this trip actually clears
            // every other guard. Otherwise a duplicate id whose FIRST
            // occurrence is cancelled/dateless would consume the slot and
            // wrongly block a LATER, genuinely valid occurrence.
            guard !existingTripIds.contains(tripUUID), !matchesLocalTripByRawId, !seenTripUUIDs.contains(tripUUID) else {
                // P6.1: `existingLocalTripId` backs the result sheet's "Open
                // trip" recourse — whichever of §5's two idempotence rules
                // matched IS the already-imported local trip; a same-archive
                // repeat (caught by `seenTripUUIDs` alone) matches neither
                // and correctly gets no recourse (there's nothing to open —
                // this exact row hasn't actually been imported at all).
                let existingLocalTripId: UUID? = matchesLocalTripByRawId
                    ? UUID(uuidString: tripIdString)
                    : (existingTripIds.contains(tripUUID) ? tripUUID : nil)
                report.tripSkips.append(.init(
                    tripId: tripIdString, title: displayTitle, reason: .alreadyImported,
                    existingLocalTripId: existingLocalTripId
                ))
                continue
            }
            if (rawTrip.status ?? "").lowercased() == "cancelled" {
                report.tripSkips.append(.init(tripId: tripIdString, title: displayTitle, reason: .cancelled))
                continue
            }
            guard let startDay = validCalendarDay(rawTrip.startDate) else {
                report.tripSkips.append(.init(tripId: tripIdString, title: displayTitle, reason: .noStartDate))
                continue
            }
            guard !displayTitle.isEmpty else {
                report.tripSkips.append(.init(tripId: tripIdString, title: displayTitle, reason: .missingTitle))
                continue
            }
            // This trip WILL be imported — claim its slot now (see the L6
            // comment above).
            seenTripUUIDs.insert(tripUUID)

            let endDay = validCalendarDay(rawTrip.endDate) ?? startDay
            let tripType = rawTrip.tripType.flatMap(TripType.init(rawValue:)) ?? .family
            let destination = nonEmpty(rawTrip.destination) ?? displayTitle
            let countryCode = rawTrip.countryCode ?? ""
            let cover = resolvedCover(rawTrip.cover, fallbackIndex: index)

            if let notes = rawTrip.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.droppedNotesCount += 1
            }

            // Same defensive dedup as `seenTripUUIDs` above, scoped to this
            // trip: a repeated traveller display name (two "Asha"s) or a
            // repeated item `id` would otherwise derive the same UUIDv5
            // twice and hit the same unique-constraint failure.
            var seenProfileUUIDs: Set<UUID> = []
            var profiles: [PreparedTripProfile] = []
            for (profileIndex, traveller) in (rawTrip.travellers ?? []).enumerated() {
                guard let name = nonEmpty(traveller) else { continue }
                let profileUUID = UUIDv5.generate(
                    namespace: TripArchiveFormat.namespace, name: "profile:\(tripIdString)/\(name)"
                )
                guard seenProfileUUIDs.insert(profileUUID).inserted else { continue }
                profiles.append(PreparedTripProfile(
                    id: profileUUID, displayName: name,
                    avatarColor: AvatarRotation.swatches[profileIndex % AvatarRotation.swatches.count]
                ))
            }

            var seenItemUUIDs: Set<UUID> = []
            var items: [PreparedTripItem] = []
            for rawItem in rawTrip.items {
                switch resolveItem(rawItem, tripIdString: tripIdString, deviceTimeZone: deviceTimeZone) {
                case .success(let item, let assumedDeviceZone):
                    guard seenItemUUIDs.insert(item.id).inserted else { continue }
                    items.append(item)
                    if assumedDeviceZone { report.zoneAssumedCount += 1 }
                case .skipped(let itemIdString, let itemLabel, let reason):
                    report.itemSkips.append(.init(
                        tripId: tripIdString, tripTitle: displayTitle, itemId: itemIdString, itemLabel: itemLabel, reason: reason
                    ))
                }
            }
            // H1 fix: an `items[]` element that wasn't even a JSON object
            // (couldn't be decoded as `ArchiveItem` at all) gets its own
            // reported skip instead of silently vanishing.
            for _ in 0..<rawTrip.unreadableItemCount {
                report.itemSkips.append(.init(
                    tripId: tripIdString, tripTitle: displayTitle, itemId: "", itemLabel: "Item", reason: .unreadable
                ))
            }

            prepared.append(PreparedTrip(
                id: tripUUID, title: displayTitle, destination: destination, countryCode: countryCode,
                startDate: startDay, endDate: endDay, tripType: tripType, coverGradient: cover,
                profiles: profiles, items: items
            ))
            report.tripsImported += 1
            report.itemsImported += items.count
            report.profilesImported += profiles.count
        }
        return (prepared, report)
    }

    // MARK: - Cover rotation

    /// The three tokens `CoverGradient` defines (`TripFormView.gradientOptions`)
    /// — an unknown/missing `cover` gets a stable rotation across the
    /// archive's own trip order rather than a fixed default, so a big
    /// import doesn't render every card identically.
    private static let coverOptions = ["dusk", "plum", "moss"]

    /// Reviewer D1 (P6.5 verify wave): a `CoverGradientGenerator` key is a
    /// genuine, distinct cover too, not just the three curated names —
    /// mirrors `TripFormView.canonicalGradientKey`'s identical "valid
    /// generated key survives as itself" rule, so an exported `gen:` cover
    /// round-trips through re-import instead of silently rewriting to a
    /// rotated curated one.
    private static func resolvedCover(_ raw: String?, fallbackIndex: Int) -> String {
        if let raw {
            let lowered = raw.lowercased()
            if coverOptions.contains(lowered) { return lowered }
            if CoverGradientGenerator.parsedHues(lowered) != nil { return lowered }
        }
        return coverOptions[fallbackIndex % coverOptions.count]
    }

    // MARK: - Item resolution (§3, §4)

    private enum ItemResolution {
        case success(PreparedTripItem, assumedDeviceZone: Bool)
        /// D2/UX#3: `itemLabel` is a best-effort title/category so a skip
        /// row can name the item, not just show a raw id (which may itself
        /// be empty, e.g. `.missingId`).
        case skipped(itemId: String, itemLabel: String, ItemSkipReason)
    }

    /// D2/UX#3: the fullest title we can show for a SKIPPED item — reuses
    /// `resolvedTitle` when `category` is known-valid (so it matches what
    /// the item's title would have been had it not been skipped for some
    /// other reason), else falls back to the raw title/category text.
    private static func bestEffortItemLabel(_ raw: ArchiveItem, category: ItemCategory?) -> String {
        if let category { return resolvedTitle(raw, category: category) }
        return nonEmpty(raw.title) ?? nonEmpty(raw.category) ?? "Item"
    }

    private static func resolveItem(
        _ raw: ArchiveItem, tripIdString: String, deviceTimeZone: TimeZone
    ) -> ItemResolution {
        guard let itemIdStringRaw = nonEmpty(raw.id) else {
            return .skipped(itemId: "", itemLabel: bestEffortItemLabel(raw, category: nil), .missingId)
        }
        // SEC LOW: clamp before it's ever hashed/stored/displayed.
        let itemIdString = clamp(itemIdStringRaw, maxLength: TripArchiveBounds.maxIdLength)
        guard let category = raw.category.flatMap(ItemCategory.init(rawValue:)) else {
            return .skipped(itemId: itemIdString, itemLabel: bestEffortItemLabel(raw, category: nil), .unknownCategory)
        }
        let usesAirports = category == .flight || category == .transport

        // §4.1: zone of starts_at — explicit tz, else (flight/transport)
        // the airport table, else the device zone (flagged).
        let (startZone, assumedDeviceZone) = resolveZone(
            explicit: raw.tz, iata: usesAirports ? raw.fromIATA : nil, fallback: deviceTimeZone
        )
        guard let startsAtRaw = nonEmpty(raw.startsAt),
            let startsAt = resolveInstant(startsAtRaw, category: category, isStart: true, zone: startZone)
        else {
            return .skipped(itemId: itemIdString, itemLabel: bestEffortItemLabel(raw, category: category), .noStartTime)
        }

        // §4.2: zone of ends_at — explicit arrival_tz, else (flight/transport)
        // the airport table, else the SAME zone as starts_at (no separate
        // "assumed" flag — that's specific to rule 1's starts_at fallback).
        let (endZone, _) = resolveZone(
            explicit: raw.arrivalTz, iata: usesAirports ? raw.toIATA : nil, fallback: startZone
        )
        let endsAt = nonEmpty(raw.endsAt).flatMap { resolveInstant($0, category: category, isStart: false, zone: endZone) }

        let title = clamp(resolvedTitle(raw, category: category), maxLength: TripArchiveBounds.maxTitleLength)
        let locationName = resolvedLocationName(raw, category: category)

        var details = ItemDetails.empty
        switch category {
        case .flight:
            details.airline = nonEmpty(raw.airline)
            details.flightNo = nonEmpty(raw.flightNo)
            details.fromIATA = nonEmpty(raw.fromIATA)?.uppercased()
            details.toIATA = nonEmpty(raw.toIATA)?.uppercased()
            details.seat = nonEmpty(raw.seat)
            details.terminal = nonEmpty(raw.terminal)
            details.gate = nonEmpty(raw.gate)
            details.arrivalTz = endZone.identifier
        case .hotel:
            details.room = nonEmpty(raw.room)
        case .activity:
            details.ticketRef = nonEmpty(raw.ticketRef)
            details.address = nonEmpty(raw.address)
        case .food:
            details.partySize = raw.partySize
            details.reservationName = nonEmpty(raw.reservationName)
            details.address = nonEmpty(raw.address)
        case .transport:
            details.provider = nonEmpty(raw.provider)
            details.dropoffLocation = nonEmpty(raw.dropoffLocation)
            details.arrivalTz = endZone.identifier
        }

        let itemUUID = UUIDv5.generate(
            namespace: TripArchiveFormat.namespace, name: "item:\(tripIdString)/\(itemIdString)"
        )
        let item = PreparedTripItem(
            id: itemUUID, category: category, title: title, startsAt: startsAt, endsAt: endsAt,
            tz: startZone.identifier, locationName: locationName,
            confirmation: nonEmpty(raw.confirmation),
            notes: nonEmpty(raw.notes).map { clamp($0, maxLength: TripArchiveBounds.maxNotesLength) },
            details: details
        )
        return .success(item, assumedDeviceZone: assumedDeviceZone)
    }

    private static func resolveZone(explicit: String?, iata: String?, fallback: TimeZone) -> (zone: TimeZone, usedFallback: Bool) {
        if let explicit, let zone = TimeZone(identifier: explicit.trimmingCharacters(in: .whitespaces)) {
            return (zone, false)
        }
        if let iata, let identifier = AirportTimeZones.tzIdentifier(for: iata), let zone = TimeZone(identifier: identifier) {
            return (zone, false)
        }
        return (fallback, true)
    }

    /// §4.4: date-only `starts_at` (and hotel's date-only `ends_at`) gets a
    /// category default local time. Reuses `ImportExtraction.swift`'s own
    /// `ImportDateParsing.parse` for the actual instant math (full-ISO8601
    /// with offset wins outright; a naive local string is read in `zone`) —
    /// a date-only string is simply rewritten with the default time first,
    /// so both paths share one parser.
    private static func resolveInstant(_ raw: String, category: ItemCategory, isStart: Bool, zone: TimeZone) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isDateOnly(trimmed) {
            let time = isStart ? categoryDefaultStartTime(category) : categoryDefaultEndTime(category)
            return ImportDateParsing.parse("\(trimmed)T\(time)", fallbackTz: zone)
        }
        return ImportDateParsing.parse(trimmed, fallbackTz: zone)
    }

    private static func isDateOnly(_ raw: String) -> Bool {
        raw.count == 10 && !raw.contains("T")
    }

    private static func categoryDefaultStartTime(_ category: ItemCategory) -> String {
        switch category {
        case .flight: return "09:00"
        case .hotel: return "15:00"
        case .activity: return "10:00"
        case .food: return "19:00"
        case .transport: return "10:00"
        }
    }

    /// Only hotel has a distinct end-of-day default (checkout, 11:00) per
    /// §4.4's parenthetical; every other category's date-only `ends_at`
    /// (an edge case the spec doesn't otherwise define) reuses its own
    /// start default for symmetry.
    private static func categoryDefaultEndTime(_ category: ItemCategory) -> String {
        category == .hotel ? "11:00" : categoryDefaultStartTime(category)
    }

    // MARK: - Titles/locations (§3)

    private static func resolvedTitle(_ raw: ArchiveItem, category: ItemCategory) -> String {
        if let title = nonEmpty(raw.title) { return title }
        guard category == .flight else { return category.rawValue.capitalized }
        let composed = [nonEmpty(raw.airline), nonEmpty(raw.flightNo)].compactMap { $0 }.joined(separator: " ")
        if !composed.isEmpty { return composed }
        if let from = nonEmpty(raw.fromIATA), let to = nonEmpty(raw.toIATA) {
            return "Flight \(from.uppercased())\u{2013}\(to.uppercased())"
        }
        return "Flight"
    }

    private static func resolvedLocationName(_ raw: ArchiveItem, category: ItemCategory) -> String {
        if let name = nonEmpty(raw.locationName) { return name }
        if category == .flight, let from = nonEmpty(raw.fromIATA) { return from.uppercased() }
        return ""
    }

    // MARK: - Shared

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// SEC LOW: bounds an untrusted string rather than failing the row —
    /// a multi-MB id/title/notes value would otherwise get stored, synced,
    /// and rendered (hanging TextKit in the report sheet) for no legitimate
    /// reason a conforming archive would ever need.
    private static func clamp(_ text: String, maxLength: Int) -> String {
        text.count > maxLength ? String(text.prefix(maxLength)) : text
    }

    /// M2 fix: `DayDate.parse` (shared with the PostgREST wire decoder,
    /// which never sees bad values) only checks that the string splits into
    /// 3 numeric parts — no calendar-validity check, so a malformed/
    /// untrusted `"2026-13-45"` or `"2026-02-29"` (non-leap year) would
    /// otherwise silently roll forward via `Calendar.date(from:)` instead of
    /// being skipped per §2. Validated here (archive-mapper-only, via a
    /// round-trip through `Calendar`) rather than tightening the shared
    /// `DayDate.parse`, which has a much larger blast radius across the app.
    private static func validCalendarDay(_ raw: String?) -> DayDate? {
        guard let raw, let day = DayDate.parse(raw) else { return nil }
        let calendar = ItineraryTimeZone.utcCalendar
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == day.year, roundTrip.month == day.month, roundTrip.day == day.day else { return nil }
        return day
    }
}

/// Shared with `TripArchiveMapper`'s profile-color rotation — same four
/// swatches `AvatarColorPicker`/`TripProfileFormSheet` offer, spelled out
/// here rather than imported so this file stays SwiftUI-free (pure/
/// hermetic, per this file's own doc comment).
enum AvatarRotation {
    static let swatches = ["amber", "moss", "sky", "plum"]
}
