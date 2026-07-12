import Foundation

// Pure, OS-version-free half of on-device paste-import (PLAN.md — sibling
// to `Platform/OnDeviceExtractor.swift`, which owns everything that
// actually touches FoundationModels). Nothing here imports
// FoundationModels or SwiftData and nothing is `@available(iOS 26.0, *)`
// — nothing here needs a real device/model to test: route decisions,
// context-window pre-estimates, and validating/mapping an already-decoded
// extraction result into insertable values, all as plain functions over
// plain types.
//
// `RawExtractedItem`/`RawExtractedPackingItem` mirror the *shape*
// `OnDeviceExtractor`'s `@Generable` types produce (flattened per-category
// `details` fields, per PLAN.md) without depending on those types
// directly — `OnDeviceExtractor` converts its `@Generable` output into
// these before ever calling into this file, so a hermetic test can build
// one by hand with no model, no macro, no availability gate.

// MARK: - Route decision

/// `PasteImportSheet.submit()`'s possible paths for a given paste, now
/// carrying WHY a `.remote` route was chosen (PLAN.md Addendum: the
/// user-selectable processing mode) — the reason drives which footer line
/// the user sees (`ImportRouting.footerVariant(for:)`) and, for `.tooLong`,
/// is the one case that's honest about an on-device MODE choice not
/// actually being honorable for this particular paste.
enum ImportRoute: Equatable {
    case onDevice
    case remote(RemoteReason)

    enum RemoteReason: Equatable {
        /// `ImportProcessingMode.cloud` (`PasteImportSheet.swift`) — the
        /// user's own choice, independent of whether on-device extraction
        /// would otherwise have been available for this paste.
        case cloudPreferred
        /// Mode is `.onDevice`, but on-device extraction isn't available on
        /// this device/OS at all (no Apple Intelligence, or an OS below the
        /// FoundationModels floor).
        case unavailable
        /// Mode is `.onDevice` and on-device extraction IS available here,
        /// but this specific paste is estimated to overflow the shared
        /// context window.
        case tooLong
    }
}

enum ImportRouting {
    /// PLAN.md Addendum's routing rule: `.cloud` mode always goes remote —
    /// it's an explicit user preference, not a fallback, so on-device
    /// availability/fit are irrelevant to it. `.onDevice` mode keeps the
    /// original rule (on-device only when the model is actually available
    /// on this device/OS *and* the pasted text is estimated to fit the
    /// shared context window), now labeling which of those two guards sent
    /// it remote instead of collapsing both into one undifferentiated
    /// `.remote`.
    static func route(mode: ImportProcessingMode, isOnDeviceAvailable: Bool, textFitsOnDevice: Bool) -> ImportRoute {
        switch mode {
        case .cloud:
            return .remote(.cloudPreferred)
        case .onDevice:
            guard isOnDeviceAvailable else { return .remote(.unavailable) }
            guard textFitsOnDevice else { return .remote(.tooLong) }
            return .onDevice
        }
    }

    /// Guideline 5.1.2(i) applies only to the third-party remote path — the
    /// on-device route never shares pasted text with anyone, so it must
    /// never show the consent dialog, regardless of whether the user has
    /// granted/declined it in the past. Every `.remote` reason (including
    /// `.cloudPreferred`, an explicit mode choice) still gates on
    /// `AIImportConsent`'s existing recorded decision, unchanged — choosing
    /// Cloud AI in the "Processing" row is a routing preference, not
    /// consent; it grants nothing on its own.
    static func requiresConsentDialog(route: ImportRoute, consentGranted: Bool) -> Bool {
        switch route {
        case .onDevice: return false
        case .remote: return !consentGranted
        }
    }

    /// Which footer line `PasteImportSheet.pasteSection` shows for a given
    /// route (PLAN.md Addendum: footer variants keyed off the route's
    /// REASON, not just on-device-vs-not). `.cloudPreferred` and
    /// `.unavailable` share the existing remote-disclosure line — both
    /// truthfully describe "this paste is going to the cloud" — while
    /// `.tooLong` gets its own honest line: the user picked on-device mode,
    /// on-device IS available, and this one paste still can't use it.
    static func footerVariant(for route: ImportRoute) -> ImportFooterVariant {
        switch route {
        case .onDevice: return .onDevicePromise
        case .remote(.cloudPreferred), .remote(.unavailable): return .remoteDisclosure
        case .remote(.tooLong): return .tooLongHonesty
        }
    }
}

/// The three footer copy states `ImportRouting.footerVariant(for:)` can
/// produce — a pure enum so the SELECTION is unit-testable without
/// rendering `PasteImportSheet`'s actual `Text` views.
enum ImportFooterVariant: Equatable {
    case onDevicePromise
    case remoteDisclosure
    case tooLongHonesty
}

// MARK: - Context-window pre-estimate

/// Conservative pre-check of whether pasted text is likely to fit
/// `SystemLanguageModel`'s shared context window, so an obviously-too-long
/// paste routes remote up front instead of paying for a doomed on-device
/// call that will just throw `exceededContextWindowSize` anyway (R4 §3).
enum ImportContextBudget {
    /// `SystemLanguageModel.default.contextSize` (verified against the
    /// actual iOS 26.5 SDK interface — fixed at 4096 for the default
    /// model), shared across instructions + schema + prompt + output for
    /// ONE `respond()` call.
    static let totalTokens = 4096

    /// ponytail: a fixed, unmeasured reserve for instructions + schema +
    /// generated output — covers the itinerary extractor's schema (the
    /// larger of the two, and the tighter budget of the two sessions), not
    /// tuned against a live model. Revisit with real on-device measurements
    /// (R4 §4: latency/token cost here is explicitly flagged unverified)
    /// if borderline pastes are routing remote more than expected.
    static let reservedTokens = 1200

    /// Conservative end of R4 §3's "~3-4 chars/token English" heuristic —
    /// assuming FEWER characters per token overestimates a given paste's
    /// token cost, so a borderline paste routes remote instead of risking
    /// a wasted on-device round trip.
    ///
    /// Review fix (CJK under-count): this used to divide `String.count`
    /// (character count) directly, which is fine for English but wildly
    /// wrong for CJK — Japanese/Chinese run closer to ~1 char/token, not
    /// ~3-4, so a character budget let a long CJK paste look "under
    /// budget," route on-device, and overflow `exceededContextWindowSize`
    /// at runtime anyway (a full wasted round-trip before falling back to
    /// remote). UTF-8 BYTE count fixes both scripts with the same
    /// constant, no per-script branching: an ASCII char is 1 byte, so
    /// "3 bytes/token" is the identical "~3 chars/token" English estimate
    /// above; a CJK char is 3 UTF-8 bytes (U+0800–U+FFFF) and ~1 token,
    /// which is ALSO ~3 bytes/token. One conservative divisor, correct
    /// (or conservative) either way.
    static let bytesPerToken = 3

    static var maxPastedTextBytes: Int { (totalTokens - reservedTokens) * bytesPerToken }

    static func textFits(_ text: String) -> Bool {
        text.utf8.count <= maxPastedTextBytes
    }
}

// MARK: - Raw (model-free) extracted shapes

/// Mirrors one item of `OnDeviceExtractor`'s `@Generable` itinerary result
/// — the same fields as backend's `EXTRACT_ITINERARY_TOOL` (`extract.ts`),
/// with per-category `details` keys flattened onto the item itself instead
/// of nested in a free-form object (PLAN.md — a small on-device model gets
/// a flat schema, not a dynamic dictionary). All detail fields are optional
/// regardless of category, same discipline as `ItemDetails` itself.
struct RawExtractedItem: Equatable {
    var category: String
    var title: String
    var startsAt: String
    var endsAt: String?
    var tz: String
    var locationName: String?
    var confirmation: String?

    // Flight
    var airline: String?
    var flightNo: String?
    var fromIATA: String?
    var toIATA: String?
    var seat: String?
    var terminal: String?
    var gate: String?
    /// Flight arrival zone / transport drop-off zone — `ItemDetails.arrivalTz`.
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

/// Mirrors one item of `OnDeviceExtractor`'s `@Generable` packing result —
/// same shape as `IngestTextResponse.PackingItemPayload`/backend's
/// `EXTRACT_PACKING_TOOL`. `groupKey` is the raw (unvalidated) string the
/// model produced; `ImportExtraction.mapPackingItem` applies the
/// whitelist-with-fallback rule.
struct RawExtractedPackingItem: Equatable {
    var label: String
    var groupKey: String
}

// MARK: - Validated/insertable shapes + mapping (mirrors backend mapItemToRow)

/// Pure validation/mapping — the client-side mirror of backend's
/// `mapItemToRow` (`extract.ts:428`), used only by the on-device path (the
/// remote path's rows are already validated server-side before the app
/// ever sees them). Malformed items are skipped (`nil`), never fatal to the
/// rest of the batch — same "one bad item doesn't sink the paste" rule
/// backend logs-and-continues on.
enum ImportExtraction {
    /// Fully validated, ready to become an `ItineraryItem` — everything
    /// `AddItemSheet.ComposedFields` would hand `save()`'s create branch,
    /// minus the fields that branch fills in itself (id, tripId, status,
    /// source, createdBy/At, updatedAt).
    struct ValidatedItineraryRow: Equatable {
        var category: ItemCategory
        var title: String
        var startsAt: Date
        var endsAt: Date?
        var tz: String
        var locationName: String
        var confirmation: String?
        var details: ItemDetails
    }

    static func mapItemToRow(_ raw: RawExtractedItem) -> ValidatedItineraryRow? {
        let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tzIdentifier = raw.tz.trimmingCharacters(in: .whitespacesAndNewlines)

        // category whitelist (`ItemCategory`'s 5 cases are the exact set
        // backend's `ALLOWED_CATEGORIES` allows) + non-empty title + a real
        // IANA tz — mirrors mapItemToRow's first two guards exactly.
        guard let category = ItemCategory(rawValue: raw.category),
            !title.isEmpty,
            let timeZone = TimeZone(identifier: tzIdentifier)
        else { return nil }

        // ISO-8601-parseable starts_at — mirrors `Number.isNaN(Date.parse(startsAt))`.
        guard let startsAt = ImportDateParsing.parse(raw.startsAt, fallbackTz: timeZone) else { return nil }

        // A flight/transport arrival zone, validated once and reused both
        // for ends_at's fallback anchor and for the stored details value —
        // an unresolvable zone is dropped rather than persisted as unusable
        // garbage (stricter than backend, which never validates this
        // sub-field; still additive/harmless to the contract).
        let resolvedArrivalTz = raw.arrivalTz.flatMap(TimeZone.init(identifier:))
        // ends_at only if parseable — mirrors mapItemToRow's `endsAt` ternary.
        let endsAt = raw.endsAt.flatMap { ImportDateParsing.parse($0, fallbackTz: resolvedArrivalTz ?? timeZone) }

        var details = ItemDetails.empty
        switch category {
        case .flight:
            details.airline = Self.nonEmpty(raw.airline)
            details.flightNo = Self.nonEmpty(raw.flightNo)
            details.fromIATA = Self.nonEmpty(raw.fromIATA)
            details.toIATA = Self.nonEmpty(raw.toIATA)
            details.seat = Self.nonEmpty(raw.seat)
            details.terminal = Self.nonEmpty(raw.terminal)
            details.gate = Self.nonEmpty(raw.gate)
            details.arrivalTz = resolvedArrivalTz?.identifier
        case .hotel:
            details.room = Self.nonEmpty(raw.room)
        case .activity:
            details.ticketRef = Self.nonEmpty(raw.ticketRef)
            details.address = Self.nonEmpty(raw.address)
        case .food:
            details.partySize = raw.partySize
            details.reservationName = Self.nonEmpty(raw.reservationName)
            details.address = Self.nonEmpty(raw.address)
        case .transport:
            details.provider = Self.nonEmpty(raw.provider)
            details.dropoffLocation = Self.nonEmpty(raw.dropoffLocation)
            details.arrivalTz = resolvedArrivalTz?.identifier
        }

        return ValidatedItineraryRow(
            category: category,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            tz: tzIdentifier,
            locationName: Self.nonEmpty(raw.locationName) ?? "",
            confirmation: Self.nonEmpty(raw.confirmation),
            details: details
        )
    }

    /// Mirrors mapItemToRow's packing-adjacent normalization
    /// (`ingest-text/index.ts`'s own packing-items loop, same file): empty
    /// label after trimming -> skip; any group key outside the 5-value
    /// whitelist -> falls back to `.custom` rather than being rejected —
    /// packing items are never dropped for an unrecognized group.
    static func mapPackingItem(_ raw: RawExtractedPackingItem) -> (label: String, groupKey: PackingGroupKey)? {
        let label = raw.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return (label: label, groupKey: PackingGroupKey(rawValue: raw.groupKey) ?? .custom)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Lenient ISO-8601 parsing

/// Parses the free-text date/time strings an extraction (on-device or,
/// hypothetically, any future client-side path) produces.
enum ImportDateParsing {
    /// Tries a full offset-bearing ISO-8601 timestamp first (the app's own
    /// `ISO8601.withFractionalSeconds`/`.withoutFractionalSeconds`
    /// formatters, `JSONCoding.swift` — the same ones every PostgREST
    /// response already round-trips through). Backend's `mapItemToRow` gets
    /// away with a bare `Date.parse(startsAt)` because its LLM is
    /// instructed the same way and a missing offset there happens to land
    /// on Deno's runtime-local time (UTC on Supabase's infra) — an on-device
    /// model asked for the same format is just as likely to omit an offset
    /// the source text never gave it, so rather than silently mis-anchoring
    /// (or rejecting) that common case, a bare "floating" date/time is read
    /// as wall-clock time *in `fallbackTz`* — the item's own validated IANA
    /// zone — which is the actually-correct instant per CLAUDE.md §7.4
    /// ("store instants in UTC with the item's own tz alongside"). Returns
    /// `nil` only when nothing recognizable parses at all, mirroring
    /// `Number.isNaN(Date.parse(...))`'s reject signal.
    static func parse(_ raw: String, fallbackTz: TimeZone) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = ISO8601.withFractionalSeconds.date(from: trimmed) { return date }
        if let date = ISO8601.withoutFractionalSeconds.date(from: trimmed) { return date }

        for format in Self.floatingFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = fallbackTz
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Ordered most- to least-specific; a non-lenient `DateFormatter`
    /// requires a full-string match, so these never cross-match each other.
    private static let floatingFormats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd"
    ]
}
