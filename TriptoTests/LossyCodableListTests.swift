import SwiftData
import XCTest
@testable import Tripto

/// `LossyCodableList<T>` — the pull-apply "one malformed row must not abort
/// the whole pull" contract (SYNC_DESIGN.md). `SyncEngine+Pull.swift`'s pull
/// methods decode every DTO array through this instead of `[T]` directly;
/// these tests exercise the decode boundary itself plus its wiring into
/// `SyncStore.applyProfiles`, entirely offline — same hermetic,
/// no-`SyncEngine`/no-network shape as `PullApplyReconcileTests`.
final class LossyCodableListTests: XCTestCase {
    /// `malformedCount` rows carry a `display_name` number instead of a
    /// string — a type mismatch, standing in for "one server row doesn't
    /// match this DTO's shape" (a narrowed column, an unexpected type).
    private func profilesJSON(valid: [(id: UUID, name: String)], malformedCount: Int) -> Data {
        var rows = valid.map { id, name in
            """
            {"id":"\(id.uuidString)","display_name":"\(name)","avatar_color":"coral","created_at":"2026-07-08T12:34:56.789+00:00","updated_at":"2026-07-08T12:34:56.789+00:00"}
            """
        }
        for _ in 0..<malformedCount {
            rows.append(
                """
                {"id":"\(UUID().uuidString)","display_name":42,"avatar_color":"coral","created_at":"2026-07-08T12:34:56.789+00:00","updated_at":"2026-07-08T12:34:56.789+00:00"}
                """
            )
        }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }

    func testDecodesValidRowsAndSkipsOneMalformedRowWithoutThrowing() throws {
        let keepA = UUID()
        let keepB = UUID()
        let json = profilesJSON(valid: [(keepA, "Ana"), (keepB, "Bo")], malformedCount: 1)

        let decoded = try JSONCoding.decoder.decode(LossyCodableList<ProfileDTO>.self, from: json)

        XCTAssertEqual(decoded.elements.count, 2, "the one malformed row must be skipped, not abort the whole decode")
        XCTAssertEqual(Set(decoded.elements.map(\.id)), [keepA, keepB])
    }

    /// The malformed row is first, not last — every test above only ever
    /// appends malformed rows at the end, so none of them can tell a real
    /// skip-and-continue from a `break`-on-first-failure bug (both would
    /// decode zero rows after the malformed one when it's last). This
    /// proves the cursor actually advances past the bad element and keeps
    /// decoding what follows it.
    func testMalformedRowBeforeValidRowsStillDecodesTheRowsThatFollow() throws {
        let keepA = UUID()
        let keepB = UUID()
        let json = Data(
            """
            [
                {"id":"\(UUID().uuidString)","display_name":42,"avatar_color":"coral","created_at":"2026-07-08T12:34:56.789+00:00","updated_at":"2026-07-08T12:34:56.789+00:00"},
                {"id":"\(keepA.uuidString)","display_name":"Ana","avatar_color":"coral","created_at":"2026-07-08T12:34:56.789+00:00","updated_at":"2026-07-08T12:34:56.789+00:00"},
                {"id":"\(keepB.uuidString)","display_name":"Bo","avatar_color":"coral","created_at":"2026-07-08T12:34:56.789+00:00","updated_at":"2026-07-08T12:34:56.789+00:00"}
            ]
            """.utf8
        )

        let decoded = try JSONCoding.decoder.decode(LossyCodableList<ProfileDTO>.self, from: json)

        XCTAssertEqual(decoded.elements.count, 2, "rows after a malformed row must still decode, not be dropped by an early stop")
        XCTAssertEqual(Set(decoded.elements.map(\.id)), [keepA, keepB])
    }

    func testAllRowsMalformedDecodesToEmptyElementsWithoutThrowing() throws {
        let json = profilesJSON(valid: [], malformedCount: 3)
        let decoded = try JSONCoding.decoder.decode(LossyCodableList<ProfileDTO>.self, from: json)
        XCTAssertTrue(decoded.elements.isEmpty)
    }

    func testEmptyArrayDecodesToEmptyElements() throws {
        let decoded = try JSONCoding.decoder.decode(LossyCodableList<ProfileDTO>.self, from: Data("[]".utf8))
        XCTAssertTrue(decoded.elements.isEmpty)
    }

    /// End-to-end through the same path `pullHome` uses (decode -> `.elements`
    /// -> `SyncStore.applyProfiles`) — the acceptance shape directly: "valid
    /// rows + one malformed row -> valid rows applied, no throw."
    func testMalformedRowIsSkippedButValidRowsStillApplyToTheStore() async throws {
        let keepA = UUID()
        let keepB = UUID()
        let json = profilesJSON(valid: [(keepA, "Ana"), (keepB, "Bo")], malformedCount: 1)
        let decoded = try JSONCoding.decoder.decode(LossyCodableList<ProfileDTO>.self, from: json)

        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        try await store.applyProfiles(decoded.elements)

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Profile>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)), [keepA, keepB])
    }
}
