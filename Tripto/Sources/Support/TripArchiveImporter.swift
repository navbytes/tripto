import Foundation
import SwiftData

/// Settings -> "Import trips" (docs/IMPORT_FORMAT.md §6) — the SwiftData/
/// sync half. Decode/validate/map is `TripArchiveMapper` (`TripArchive.swift`,
/// pure, no SwiftData); this file only turns `PreparedTrip`s into rows,
/// mirroring `DemoSeeder`'s exact phased-write pattern: trips inserted and
/// pushed first (so the server's trip-creation trigger seats each organizer)
/// before the profiles that reference them, then items — an explicit flush
/// between phases rather than trusting the debounced queue's ordering across
/// a large burst of same-instant enqueues. `syncEngine` is `SyncEngine?`
/// exactly like `DemoSeeder.seed`, so callers (and tests) never need a real
/// engine/network.
enum TripArchiveImporter {
    /// D2/M3: deliberately NOT `@MainActor` — a 200-trip archive's `decode`
    /// + `map` (up to ~400k `DateFormatter` invocations inside
    /// `ImportDateParsing`) used to run synchronously on the main actor and
    /// freeze the UI. This function's own body has no actor affinity, so
    /// that CPU-bound work now runs off the main actor; only the two
    /// SwiftData-touching halves (`fetchExistingTripIds`, `persist`) hop
    /// back via their own `@MainActor` annotation.
    static func importArchive(
        data: Data, modelContext: ModelContext, syncEngine: SyncEngine?, userId: UUID
    ) async -> Result<TripArchiveImportReport, TripArchiveError> {
        let document: ArchiveDocument
        do {
            document = try TripArchiveMapper.decode(data)
        } catch let archiveError as TripArchiveError {
            return .failure(archiveError)
        } catch {
            return .failure(.invalidJSON)
        }

        let existingIds: Set<UUID>
        do {
            existingIds = try await fetchExistingTripIds(modelContext: modelContext)
        } catch {
            // L7 fix: a fetch failure used to silently degrade to an empty
            // set (risking a duplicate import) rather than failing loudly.
            return .failure(.writeFailed)
        }
        let (preparedTrips, report) = TripArchiveMapper.map(document: document, existingTripIds: existingIds)
        guard !preparedTrips.isEmpty else { return .success(report) }

        return await persist(preparedTrips: preparedTrips, report: report, modelContext: modelContext, syncEngine: syncEngine, userId: userId)
    }

    @MainActor
    private static func fetchExistingTripIds(modelContext: ModelContext) throws -> Set<UUID> {
        Set(try modelContext.fetch(FetchDescriptor<Trip>()).map(\.id))
    }

    @MainActor
    private static func persist(
        preparedTrips: [PreparedTrip], report: TripArchiveImportReport,
        modelContext: ModelContext, syncEngine: SyncEngine?, userId: UUID
    ) async -> Result<TripArchiveImportReport, TripArchiveError> {
        let now = Date()
        var trips: [Trip] = []
        var profiles: [TripProfile] = []
        var items: [ItineraryItem] = []

        for prepared in preparedTrips {
            let trip = Trip(
                id: prepared.id, title: prepared.title, destination: prepared.destination,
                countryCode: prepared.countryCode, startDate: prepared.startDate.asDate(),
                endDate: prepared.endDate.asDate(), coverGradient: prepared.coverGradient,
                tripTypeRaw: prepared.tripType.rawValue, createdBy: userId,
                createdAt: now, updatedAt: now, updatedBy: nil
            )
            trips.append(trip)
            modelContext.insert(trip)
            // Local-only provisional organizer membership, same as
            // `DemoSeeder`/`TripFormView.save()` — inserted locally but
            // NEVER enqueued; the server's trip-creation trigger seats the
            // real `trip_members` row (and organizer `trip_profiles` row)
            // once the trip upsert below lands.
            modelContext.insert(TripMember(
                id: UUID(), tripId: trip.id, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now
            ))
            for preparedProfile in prepared.profiles {
                let profile = TripProfile(
                    id: preparedProfile.id, tripId: trip.id, displayName: preparedProfile.displayName,
                    avatarColor: preparedProfile.avatarColor, linkedUserId: nil, createdAt: now
                )
                profiles.append(profile)
                modelContext.insert(profile)
            }
            for preparedItem in prepared.items {
                let item = ItineraryItem(
                    id: preparedItem.id, tripId: trip.id, categoryRaw: preparedItem.category.rawValue,
                    title: preparedItem.title, startsAt: preparedItem.startsAt, endsAt: preparedItem.endsAt,
                    tz: preparedItem.tz, locationName: preparedItem.locationName,
                    locationLat: nil, locationLng: nil, confirmation: preparedItem.confirmation,
                    notes: preparedItem.notes, detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue,
                    sourceRaw: ItemSource.manual.rawValue, createdBy: userId,
                    createdAt: now, updatedAt: now, updatedBy: nil
                )
                item.details = preparedItem.details
                items.append(item)
                modelContext.insert(item)
            }
        }

        do {
            try modelContext.save()
        } catch {
            // M4 fix: without this, the up-to-100k inserted-but-unsaved
            // objects stay registered on the shared main `ModelContext` —
            // SwiftData autosave (or the next unrelated save anywhere)
            // could later commit a "failed" import.
            modelContext.rollback()
            return .failure(.writeFailed)
        }

        guard let syncEngine else { return .success(report) }

        for trip in trips {
            await syncEngine.enqueueUpsert(table: .trips, rowId: trip.id, tripId: trip.id, payload: trip.toDTO())
        }
        await syncEngine.flushPush()
        for profile in profiles {
            await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: profile.id, tripId: profile.tripId, payload: profile.toDTO())
        }
        await syncEngine.flushPush()
        for item in items {
            await syncEngine.enqueueUpsert(table: .itineraryItems, rowId: item.id, tripId: item.tripId, payload: item.toDTO())
        }
        await syncEngine.flushPush()

        return .success(report)
    }
}
