#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

// PLAN.md: ALL FoundationModels code lives in this one file — @Generable
// schemas, session setup, and the two on-device extractions (itinerary +
// packing) that mirror backend's `EXTRACT_ITINERARY_TOOL`/
// `EXTRACT_PACKING_TOOL` (`~/repos/backend/projects/tripto/functions/
// _shared/extract.ts`). Everything here is wrapped in
// `#if canImport(FoundationModels)` (compile-time — this repo's toolchain
// always has the framework, but this is the verified belt-and-suspenders
// pattern, R4 §6) and `@available(iOS 26.0, *)` (runtime — load-bearing,
// since the app's deployment target is iOS 17). Callers outside this file
// (`PasteImportSheet.swift`) always reach in through the same two-guard
// combo, never assume either check already happened elsewhere.
//
// Everything below produces the plain, model-free types
// `Features/Trip/ImportExtraction.swift` defines
// (`RawExtractedItem`/`RawExtractedPackingItem`) — validation/mapping and
// every other testable decision live there, not here. This file is
// intentionally the *only* place a unit test can't reach (R4 §6: "do not
// attempt to unit-test actual model calls; do NOT invent a mock of Apple's
// session").

#if canImport(FoundationModels)

// MARK: - @Generable schema
//
// Fields are flattened per-category `details` keys living directly on the
// item (PLAN.md) rather than a nested free-form object — unlike backend's
// LLM, which can be handed a dynamic JSON `details` blob, a `@Generable`
// schema can only describe concrete typed fields. `GenerableItemCategory`'s
// raw values match `ItemCategory` exactly (`Models/Enums.swift`) and
// `GenerablePackingGroup`'s match `PackingGroupKey`, so converting into
// `RawExtractedItem`/`RawExtractedPackingItem` below is a plain `.rawValue`
// read, not a translation table.

@available(iOS 26.0, *)
@Generable
enum GenerableItemCategory: String {
    case flight
    case hotel
    case activity
    case food
    case transport
}

@available(iOS 26.0, *)
@Generable
struct GenerableItineraryItem: Equatable {
    @Guide(description: "Category of this booking or scheduled activity.")
    var category: GenerableItemCategory

    @Guide(description: "Short human-readable title, e.g. 'TAP Air Portugal TP1234' or 'Okinawa Churaumi Aquarium'.")
    var title: String

    @Guide(
        description:
            "ISO 8601 date and time of departure/check-in/reservation/pickup/activity start, e.g. "
            + "2026-07-14T09:00:00. Include a timezone offset only if the source text explicitly states one."
    )
    var startsAt: String

    @Guide(
        description:
            "ISO 8601 date and time of arrival/check-out/drop-off/activity end, if the text states one. "
            + "Omit for a plain activity or restaurant reservation with no end time."
    )
    var endsAt: String?

    @Guide(
        description:
            "IANA time zone name for startsAt, e.g. 'Europe/Lisbon' or 'America/New_York' — infer from the "
            + "destination/context if the text doesn't say."
    )
    var tz: String

    @Guide(description: "Airport, hotel, venue, or restaurant name or address. Omit if not present.")
    var locationName: String?

    @Guide(description: "Booking or confirmation code, exactly as written. Omit if none is present.")
    var confirmation: String?

    // Flight
    @Guide(description: "Airline name. Flight only — omit for every other category.")
    var airline: String?
    @Guide(description: "Flight number. Flight only — omit for every other category.")
    var flightNo: String?
    @Guide(description: "Departure airport IATA code. Flight only — omit for every other category.")
    var fromIATA: String?
    @Guide(description: "Arrival airport IATA code. Flight only — omit for every other category.")
    var toIATA: String?
    @Guide(description: "Seat number. Flight only. Omit if not present.")
    var seat: String?
    @Guide(description: "Departure terminal. Flight only. Omit if not present.")
    var terminal: String?
    @Guide(description: "Departure gate. Flight only. Omit if not present.")
    var gate: String?
    @Guide(
        description:
            "IANA time zone of the arrival airport (flight) or drop-off location (transport), only if "
            + "different from tz. Omit otherwise."
    )
    var arrivalTz: String?

    // Hotel
    @Guide(description: "Room number or type. Hotel only. Omit if not present.")
    var room: String?

    // Activity
    @Guide(description: "Ticket or admission reference. Activity only. Omit if not present.")
    var ticketRef: String?

    // Food
    @Guide(description: "Party size. Food only. Omit if not stated.")
    var partySize: Int?
    @Guide(description: "Name the reservation is under. Food only. Omit if not present.")
    var reservationName: String?

    // Transport
    @Guide(description: "Rental/transport provider name. Transport only. Omit if not present.")
    var provider: String?
    @Guide(description: "Drop-off location. Transport only. Omit if not present.")
    var dropoffLocation: String?

    // Activity & food
    @Guide(description: "Street address. Activity or food only. Omit if not present.")
    var address: String?
}

@available(iOS 26.0, *)
@Generable
struct GenerableItineraryResult: Equatable {
    @Guide(
        description: "One entry per distinct scheduled booking or activity found in the text. Empty if nothing was found.",
        .maximumCount(30)
    )
    var items: [GenerableItineraryItem]
}

@available(iOS 26.0, *)
@Generable
enum GenerablePackingGroup: String {
    case documents
    case kids
    case shared
    case clothing
    case custom
}

@available(iOS 26.0, *)
@Generable
struct GenerablePackingItem: Equatable {
    @Guide(description: "Short human-readable name of the item to pack, e.g. 'Passport' or 'Sunscreen'.")
    var label: String

    @Guide(
        description:
            "documents: passports, tickets, IDs, visas, insurance docs. kids: child-specific gear. "
            + "clothing: apparel/footwear. shared: group/household items like chargers, first-aid, "
            + "sunscreen, toiletries. custom: anything else, or anything that doesn't clearly fit."
    )
    var groupKey: GenerablePackingGroup
}

@available(iOS 26.0, *)
@Generable
struct GenerablePackingResult: Equatable {
    @Guide(description: "True if the text is a packing list, or contains one.")
    var isPackingList: Bool

    @Guide(description: "One entry per distinct item to pack. Empty if isPackingList is false.", .maximumCount(30))
    var items: [GenerablePackingItem]
}

/// Packing SUGGESTIONS (PLAN.md ai-garnish) — no `isPackingList` gate (unlike
/// `GenerablePackingResult` above): there is no source text to judge as
/// "a packing list or not," the model is asked to generate new items from
/// the trip's own context instead. Same `GenerablePackingItem` vocabulary,
/// so `OnDeviceExtractor.toRaw(_ item: GenerablePackingItem)` below already
/// converts this result's items too.
@available(iOS 26.0, *)
@Generable
struct GenerablePackingSuggestions: Equatable {
    @Guide(
        description: "One entry per suggested packing item this trip doesn't already have. Empty if nothing else is needed.",
        .maximumCount(20)
    )
    var items: [GenerablePackingItem]
}

// MARK: - Extractor

@available(iOS 26.0, *)
enum OnDeviceExtractor {
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Called when the paste-import sheet appears and on-device extraction
    /// is the likely route (R4 §4: give the system "at least ~1 second of
    /// lead time" before the user taps Import). A hint only — "does not
    /// guarantee immediate loading" — so this never blocks or throws.
    /// Warms both sessions since either extraction can end up being the one
    /// that matters for whatever the user pastes.
    static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: Self.itineraryInstructions).prewarm()
        LanguageModelSession(instructions: Self.packingInstructions).prewarm()
    }

    enum Outcome {
        case success(items: [RawExtractedItem], packing: [RawExtractedPackingItem])
        /// Either sub-extraction hard-failed — PLAN.md: discard on-device
        /// results entirely and fall back to remote (single semantics, no
        /// partial mixing). An empty result on either side is NOT this case
        /// — see `extractAll` below.
        case fallback
    }

    /// Runs both extractions concurrently over the SAME pasted text (two
    /// independent, short-lived sessions — R4 §4's "session reuse" guidance:
    /// one-shot calls should each get a fresh session rather than sharing
    /// one), mirroring backend's parallel `Promise.allSettled` shape but
    /// with stricter all-or-nothing semantics per PLAN.md.
    static func extractAll(from text: String) async -> Outcome {
        async let itineraryTask = Self.extractItinerary(from: text)
        async let packingTask = Self.extractPacking(from: text)
        do {
            let items = try await itineraryTask
            let packing = try await packingTask
            return .success(items: items, packing: packing)
        } catch {
            // KISS/YAGNI: every `GenerationError` case fell back to remote
            // identically — a named classifier switch existed only to name
            // *why* in the log, which `error`'s own description already
            // does, so it was collapsed to a bare catch (finding #2).
            logDebug("OnDeviceExtractor: falling back to remote after \(error)")
            return .fallback
        }
    }

    private static func extractItinerary(from text: String) async throws -> [RawExtractedItem] {
        let session = LanguageModelSession(instructions: Self.itineraryInstructions)
        let response = try await session.respond(
            to: text,
            generating: GenerableItineraryResult.self,
            options: GenerationOptions(sampling: .greedy)
        )
        return response.content.items.map(Self.toRaw)
    }

    private static func extractPacking(from text: String) async throws -> [RawExtractedPackingItem] {
        let session = LanguageModelSession(instructions: Self.packingInstructions)
        let response = try await session.respond(
            to: text,
            generating: GenerablePackingResult.self,
            options: GenerationOptions(sampling: .greedy)
        )
        // Mirrors backend's `is_packing_list` gate (functions/ingest-text/
        // index.ts: `if (parsed?.is_packing_list && Array.isArray(...))`) —
        // unlike the itinerary side (which deliberately dropped its
        // equivalent boolean after a confirmed-live regression, see
        // `GenerableItineraryResult`'s lack of one), packing's gate is
        // still live and untouched server-side, so this mirrors it as-is.
        guard response.content.isPackingList else { return [] }
        return response.content.items.map(Self.toRaw)
    }

    // MARK: - Trip summary ("Catch me up")

    /// No `@Generable` schema here (unlike every extraction above) — this is
    /// prose for a person to read, not structured data the app parses, so
    /// it uses `respond(to:)`'s plain-`String`-generating overload. `context`
    /// is `TripPromptContext.render(...)`'s output (`Models/
    /// TripPromptContext.swift`) — the ONLY trip-derived input, passed as
    /// `respond(to:)`'s prompt argument exactly like `extractItinerary`/
    /// `extractPacking` above (R4 §5's hard security boundary: instructions
    /// stay a fixed string, data only ever arrives as the prompt).
    enum SummaryOutcome {
        case success(String)
        case failure
    }

    static func summarizeTrip(context: String) async -> SummaryOutcome {
        let session = LanguageModelSession(instructions: Self.summaryInstructions)
        do {
            let response = try await session.respond(to: context, options: GenerationOptions(sampling: .greedy))
            return .success(response.content)
        } catch {
            logDebug("OnDeviceExtractor: summarizeTrip failed: \(error)")
            return .failure
        }
    }

    // MARK: - Packing suggestions

    /// `context` carries the trip's own details PLUS its existing packing
    /// labels (`TripPromptContext.render(existingPackingLabels:)`) so the
    /// model has something to avoid repeating — the real duplicate guard is
    /// still client-side (`Features/Trip/PackingSuggestions.dedupe`), never
    /// trusted from the model alone.
    enum PackingSuggestionOutcome {
        case success([RawExtractedPackingItem])
        case failure
    }

    static func suggestPacking(context: String) async -> PackingSuggestionOutcome {
        let session = LanguageModelSession(instructions: Self.packingSuggestionInstructions)
        do {
            let response = try await session.respond(
                to: context,
                generating: GenerablePackingSuggestions.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return .success(response.content.items.map(Self.toRaw))
        } catch {
            logDebug("OnDeviceExtractor: suggestPacking failed: \(error)")
            return .failure
        }
    }

    private static func toRaw(_ item: GenerableItineraryItem) -> RawExtractedItem {
        RawExtractedItem(
            category: item.category.rawValue,
            title: item.title,
            startsAt: item.startsAt,
            endsAt: item.endsAt,
            tz: item.tz,
            locationName: item.locationName,
            confirmation: item.confirmation,
            airline: item.airline,
            flightNo: item.flightNo,
            fromIATA: item.fromIATA,
            toIATA: item.toIATA,
            seat: item.seat,
            terminal: item.terminal,
            gate: item.gate,
            arrivalTz: item.arrivalTz,
            room: item.room,
            ticketRef: item.ticketRef,
            partySize: item.partySize,
            reservationName: item.reservationName,
            provider: item.provider,
            dropoffLocation: item.dropoffLocation,
            address: item.address
        )
    }

    private static func toRaw(_ item: GenerablePackingItem) -> RawExtractedPackingItem {
        RawExtractedPackingItem(label: item.label, groupKey: item.groupKey.rawValue)
    }

    // MARK: - Instructions
    //
    // Fixed task descriptions only — the untrusted pasted text is NEVER
    // interpolated here, only ever passed as `respond(to:)`'s prompt
    // argument (R4 §5's "hard security boundary, not a style choice").

    private static let itineraryInstructions = """
        You extract structured itinerary items from text a user pasted into a trip-planning app on \
        their own device — both formal bookings/reservations AND planned activities with a specific \
        time and place (e.g. "museum at 9am", "dinner at Y 8pm"). Use ONLY information present in the \
        text; never invent confirmation codes, dates, names, or addresses — omit a field rather than \
        guessing. Skip vague mentions with no specific time: general advice, packing reminders, \
        weather notes, or recommendations with no scheduled slot.
        """

    private static let packingInstructions = """
        You extract a packing list from text a user pasted into a trip-planning app on their own \
        device, if the text is or contains one. Use ONLY items present in the text; never invent \
        items. If the text is not a packing list, set isPackingList to false and return no items.
        """

    private static let summaryInstructions = """
        You write a short "catch me up" summary of a trip for someone opening a trip-planning app on \
        their own device. Using ONLY the trip details provided, summarize the destination and dates, \
        who's going, and the key upcoming bookings and activities in 3-4 short sentences a busy \
        traveler can skim in a few seconds. Do not invent any detail that isn't in the provided trip \
        details.
        """

    private static let packingSuggestionInstructions = """
        You suggest practical packing items for a trip planned in a trip-planning app on the user's \
        own device. Given the trip's details and the items already on its packing list, suggest \
        additional items that make sense for this trip. Never repeat or rename an item already on the \
        list. Only suggest concrete physical items to pack, not advice or reminders.
        """
}

#endif
