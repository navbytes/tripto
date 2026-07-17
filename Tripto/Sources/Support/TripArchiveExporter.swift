import Foundation
import SwiftData

/// Settings -> "Export trips" (BACKLOG §E3 "Download my data",
/// docs/IMPORT_FORMAT.md §7) — writes every local trip out as the same
/// Tripto Archive v1 format `TripArchiveImporter` reads.
///
/// `composeDocument` is pure (plain `Trip`/`ItineraryItem`/`TripProfile`
/// arrays in, `ArchiveDocument` out — no `ModelContext`), matching
/// `TripArchive.swift`'s "pure mapping unit-tests without SwiftData" rule;
/// this file's only SwiftData-touching bit is the plain `modelContext.fetch`
/// call sites make before handing the arrays here.
enum TripArchiveExporter {
    /// D3 fix (N1): `export` itself is nonisolated so `encode`/`writeTempFile`
    /// (pure over the Sendable `ArchiveDocument`/`Data` `composeDocument`
    /// already produced — where the real O(trips × items) cost is for a
    /// large export) run off the main actor. But `composeDocument` READS
    /// `@Model` properties (`trip.title`, `item.startsAt`, `item.details`,
    /// …) — `Trip`/`ItineraryItem`/`TripProfile` are non-Sendable and bound
    /// to the main `ModelContext`, so that call must happen ON the main
    /// actor (`MainActor.run`), not off it. Do NOT hand `@Model` arrays
    /// across the boundary the way the encode/write half safely can.
    static func export(trips: [Trip], items: [ItineraryItem], profiles: [TripProfile]) async throws -> URL {
        let document = await MainActor.run {
            composeDocument(trips: trips, items: items, profiles: profiles)
        }
        let data = try encode(document)
        return try writeTempFile(data)
    }

    /// §7: scope is every local trip (the local mirror is already RLS-scoped
    /// server-side); `travellers` are a trip's unlinked profiles; `status`
    /// is derived from dates, reusing the same `TripDateBucketing` the rest
    /// of the app buckets Upcoming/Past with. `today`/`calendar` are
    /// injectable so the date-derived `status` is testable without depending
    /// on the real clock.
    static func composeDocument(
        trips: [Trip], items: [ItineraryItem], profiles: [TripProfile],
        exportedAt: Date = .now, today: Date = .now, calendar: Calendar = .current
    ) -> ArchiveDocument {
        let archiveTrips = trips.map { trip in
            archiveTrip(for: trip, items: items, profiles: profiles, today: today, calendar: calendar)
        }
        return ArchiveDocument(
            format: TripArchiveFormat.identifier,
            version: TripArchiveFormat.supportedVersion,
            exportedAt: ISO8601.withFractionalSeconds.string(from: exportedAt),
            trips: archiveTrips
        )
    }

    private static func archiveTrip(
        for trip: Trip, items: [ItineraryItem], profiles: [TripProfile], today: Date, calendar: Calendar
    ) -> ArchiveTrip {
        let tripItems = items.filter { $0.tripId == trip.id }
        // Unlinked = no account (BUILD_PLAN §3.3) — a linked profile is the
        // trigger-created organizer/companion row, not a "traveller" the
        // archive format adds back on import.
        let travellerNames = profiles
            .filter { $0.tripId == trip.id && $0.linkedUserId == nil }
            .map(\.displayName)
        let isPast = TripDateBucketing.bucket(startDate: trip.startDate, endDate: trip.endDate, today: today, calendar: calendar).isPastTab

        return ArchiveTrip(
            id: trip.id.uuidString,
            title: trip.title,
            destination: trip.destination,
            countryCode: trip.countryCode,
            startDate: DayDate.from(trip.startDate, calendar: calendar).stringValue,
            endDate: DayDate.from(trip.endDate, calendar: calendar).stringValue,
            tripType: trip.tripTypeRaw,
            status: isPast ? "completed" : "upcoming",
            cover: trip.coverGradient,
            travellers: travellerNames,
            items: tripItems.map(archiveItem),
            // §2/§7: trips have no notes column in this app — never emitted.
            notes: nil
        )
    }

    private static func archiveItem(_ item: ItineraryItem) -> ArchiveItem {
        let details = item.details
        return ArchiveItem(
            id: item.id.uuidString,
            category: item.categoryRaw,
            title: item.title,
            // Full ISO8601-with-offset — the exact stored UTC instant, so a
            // later re-import doesn't need to re-resolve anything to get
            // the same instant back (§4.3: an explicit offset always wins).
            startsAt: ISO8601.withFractionalSeconds.string(from: item.startsAt),
            endsAt: item.endsAt.map { ISO8601.withFractionalSeconds.string(from: $0) },
            tz: item.tz,
            locationName: item.locationName,
            confirmation: item.confirmation,
            notes: item.notes,
            airline: details.airline,
            flightNo: details.flightNo,
            fromIATA: details.fromIATA,
            toIATA: details.toIATA,
            seat: details.seat,
            terminal: details.terminal,
            gate: details.gate,
            arrivalTz: details.arrivalTz,
            room: details.room,
            ticketRef: details.ticketRef,
            partySize: details.partySize,
            reservationName: details.reservationName,
            provider: details.provider,
            dropoffLocation: details.dropoffLocation,
            address: details.address
        )
    }

    /// Own `JSONEncoder` (not `Models/JSONCoding.swift`'s) — pretty-printed,
    /// since this is a human-downloadable "my data" file, not a wire payload.
    static func encode(_ document: ArchiveDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Writes the encoded archive to a fresh temp file named per §7's
    /// convention, ready for `SettingsView`'s share sheet.
    static func writeTempFile(_ data: Data, today: Date = .now, calendar: Calendar = .current) throws -> URL {
        let formatter = ItineraryTimeZone.posixFormatter("yyyy-MM-dd", calendar: calendar)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripto-archive-\(formatter.string(from: today))")
            .appendingPathExtension("json")
        // SEC LOW: this file carries PNRs/confirmation codes — protect it
        // at rest same as the rest of the app's sandbox data; `SettingsView`
        // deletes it once the share sheet dismisses.
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
