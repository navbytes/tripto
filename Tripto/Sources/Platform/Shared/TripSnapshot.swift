import Foundation

/// App Group shared by `Tripto` and `TriptoWidgets` — the one identifier
/// both targets' entitlements carry (`project.yml`) and the anchor for the
/// shared container `TripSnapshot.load()`/`save()` read and write.
/// PLAN-signature-layer.md §D6: frozen on W2-A's merge.
public enum AppGroup {
    public static let id = "group.io.navbytes.tripto"
}

/// The one glanceable-surface contract (§D6): widgets, the Live Activity
/// start condition, App Intents, and Spotlight indexing (W2-B/C) all read
/// this file instead of opening SwiftData — `TriptoWidgets` never links
/// `Data/`/`Models/` (no SwiftData in the extension), so this type and
/// everything it embeds is deliberately self-contained. The app-side
/// writer (`Data/SyncStore+Snapshot.swift`, app-only) is what actually
/// maps `Trip`/`ItineraryItem` into these shapes.
///
/// **Sanitized by construction, not by filtering**: there is no field here
/// a confirmation code, note, or email could hide in (BUILD_PLAN §7.5 —
/// the same instinct as the public share link's sanitized payload). Adding
/// a field later means it lands on the lock screen/Spotlight/Siri — think
/// about that before adding one.
///
/// Consumers compute "next"/"today" against `Date.now` themselves (not
/// against `generatedAt`), so the file doesn't go stale at midnight.
public struct TripSnapshot: Codable, Sendable, Equatable {
    /// Bumped when the shape below changes in a way an older reader
    /// couldn't safely decode — `load()` treats a mismatch as "no
    /// snapshot" (same as a missing file) rather than a partial decode.
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    /// Upcoming + in-progress trips only, max 6, soonest-starting first
    /// (in-progress trips sort first, same as `HomeView`'s own
    /// `@Query(sort: \Trip.startDate)`).
    public var trips: [SnapshotTrip]
    /// Items for ONE trip — the in-progress trip if any, else the next
    /// upcoming one (`SyncStore.buildSnapshot`'s selection). Max 100,
    /// soonest-starting first.
    public var focusTripItems: [SnapshotItem]

    public init(generatedAt: Date, trips: [SnapshotTrip], focusTripItems: [SnapshotItem]) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.trips = trips
        self.focusTripItems = focusTripItems
    }
}

public struct SnapshotTrip: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    /// `Trip.coverGradient`'s token key ("dusk"/"plum"/"moss") — resolve
    /// via `CoverGradient.from(key:)`, same as everywhere else in the app.
    public var coverGradient: String
    /// Local-midnight `Date` for each calendar day — the same
    /// representation `Trip.startDate`/`endDate` already use (plain
    /// wall-calendar days, no time zone attached; see `Trip`'s own doc
    /// comment). Not `DayDate` — that type lives in `Models/`, off-limits
    /// to the widget extension.
    public var startDate: Date
    public var endDate: Date
    public var destination: String

    public init(id: UUID, title: String, coverGradient: String, startDate: Date, endDate: Date, destination: String) {
        self.id = id
        self.title = title
        self.coverGradient = coverGradient
        self.startDate = startDate
        self.endDate = endDate
        self.destination = destination
    }
}

public struct SnapshotItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var tripId: UUID
    public var title: String
    public var category: Category
    /// UTC instant + its own IANA zone (§7.4) — render in `tz`, never the
    /// device's zone.
    public var startsAt: Date
    public var endsAt: Date?
    public var tz: String
    public var fromIATA: String?
    public var toIATA: String?
    public var flightNo: String?
    public var locationName: String

    public init(
        id: UUID, tripId: UUID, title: String, category: Category,
        startsAt: Date, endsAt: Date?, tz: String,
        fromIATA: String?, toIATA: String?, flightNo: String?, locationName: String
    ) {
        self.id = id
        self.tripId = tripId
        self.title = title
        self.category = category
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.tz = tz
        self.fromIATA = fromIATA
        self.toIATA = toIATA
        self.flightNo = flightNo
        self.locationName = locationName
    }

    /// Mirrors `ItemCategory`'s raw values exactly, as a distinct type
    /// rather than reusing `ItemCategory` itself — that enum lives in
    /// `Models/`, which the widget extension deliberately never compiles.
    public enum Category: String, Codable, Sendable, CaseIterable {
        case flight
        case hotel
        case activity
        case food
        case transport
    }
}

// MARK: - Load / save (App Group container)

public enum TripSnapshotError: Error {
    /// No App Group container for this process — an unsigned build, or a
    /// target (like `TriptoTests`) that was never granted the
    /// `group.io.navbytes.tripto` capability (this repo's signed-build
    /// gotcha: an unsigned build "lies" about entitlements).
    case noContainer
}

extension TripSnapshot {
    private static let fileName = "snapshot.json"

    /// The App Group container directory, or `nil` if this process has no
    /// access to it. Exposed (rather than baked into `load`/`save`) so
    /// tests can point at a scratch directory instead of the real group.
    public static var groupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
    }

    /// Reads `snapshot.json` from `directory`. `nil` means "nothing to
    /// show" — missing file, unreadable container, or a stale `version` —
    /// every consumer (widgets, intents, Spotlight) treats that the same
    /// way: render the empty/placeholder state.
    public static func load(from directory: URL? = groupContainerURL) -> TripSnapshot? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
            return nil
        }
        guard let snapshot = try? decoder.decode(TripSnapshot.self, from: data), snapshot.version == currentVersion else {
            return nil
        }
        return snapshot
    }

    /// Atomic write so a concurrent `load()` (a widget timeline refresh
    /// mid-write) never observes a half-written file.
    public func save(to directory: URL? = TripSnapshot.groupContainerURL) throws {
        guard let directory else { throw TripSnapshotError.noContainer }
        let data = try TripSnapshot.encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(TripSnapshot.fileName), options: .atomic)
    }

    /// Sign-out: remove the file entirely rather than writing an empty
    /// snapshot — `load()` returning `nil` is indistinguishable from
    /// "never written," which is the honest post-wipe state (privacy: a
    /// widget must never keep showing the previous account's trip).
    public static func clear(in directory: URL? = groupContainerURL) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// Self-contained coder — not `JSONCoding` (`Models/JSONCoding.swift`),
    /// off-limits to the widget extension for the same reason as
    /// `DayDate`/`ItemCategory` above. This file is only ever read by code
    /// that also wrote it, so (unlike `JSONCoding`, which tolerates
    /// PostgREST's varying fractional-seconds formatting) a single ISO8601
    /// formatter is enough.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = iso8601.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
