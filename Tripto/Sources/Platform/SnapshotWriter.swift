import ActivityKit
import Foundation
import WidgetKit

/// The one place a data change turns into a written `TripSnapshot` — every
/// glanceable surface (widgets today; Spotlight/App Intents from W2-C)
/// reads the file this writes, never SwiftData directly
/// (PLAN-signature-layer.md §D6).
///
/// App-only (not compiled into `TriptoWidgets`). Debounced like
/// `SyncEngine.schedulePush()` — same task-cancel pattern — so a burst of
/// mutations (e.g. `DemoSeeder`'s ~70-row seed) collapses into one write
/// ~800ms after the burst settles, not one write per row.
///
/// Hook set (see call sites): `SyncEngine.pullHome()`/`pullTrip()` success,
/// every `SyncEngine.enqueue*` call that touches a snapshot-relevant table,
/// `TriptoApp`'s `scenePhase -> .background`, and
/// `SyncEngine.wipeForSignOut()` (-> `clear()`).
///
/// An `actor` for the same reason `SyncEngine` is one: the debounce task
/// and the eventual `SyncStore` read both need one serialized owner, and
/// nothing here needs to be `@MainActor` — no view reads this type
/// directly.
actor SnapshotWriter {
    private let store: SyncStore
    private var writeTask: Task<Void, Never>?
    private static let debounceMilliseconds: UInt64 = 800

    /// Frozen extension point (§D6): fires with the freshly-written
    /// snapshot after every real write, and with `nil` after `clear()`.
    /// W2-C attaches Spotlight indexing here — same moment, same debounce,
    /// "one pipeline." Mutated only through `setOnWrite(_:)` below — an
    /// actor-isolated stored property can't be assigned directly from
    /// outside (`await writer.onWrite = ...` doesn't compile; the compiler
    /// itself suggests an isolated method), and this codebase's own
    /// convention for actor state a caller needs to push in from outside
    /// is a `setXxx` method anyway (see every `SyncStatus.setXxx` call
    /// from `SyncEngine`).
    private(set) var onWrite: ((TripSnapshot?) -> Void)?

    init(store: SyncStore) {
        self.store = store
    }

    /// W2-C: `await syncEngine.snapshotWriter.setOnWrite(SpotlightIndexer.handle)`
    /// (or equivalent) from `TriptoApp` to attach Spotlight indexing.
    func setOnWrite(_ handler: @escaping (TripSnapshot?) -> Void) {
        onWrite = handler
    }

    /// Debounced "something changed" signal — cheap and safe to call from
    /// every hook site without each one worrying about coalescing.
    func notifyDataChanged() {
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(nanoseconds: Self.debounceMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    /// Sign-out: cancel any in-flight debounced write, delete the file,
    /// end any running Live Activity, and tell widgets/Spotlight there's
    /// nothing to show — privacy (§D6): no surface may keep displaying the
    /// previous account's trip after sign-out. (Security audit wave-2: the
    /// LA end was the one surface this originally missed — a signed-out
    /// user's flight stayed on the lock screen until departure+45m.)
    func clear() async {
        writeTask?.cancel()
        writeTask = nil
        TripSnapshot.clear()
        for activity in Activity<TravelDayAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        WidgetCenter.shared.reloadAllTimelines()
        onWrite?(nil)
    }

    private func write() async {
        do {
            let snapshot = try await store.buildSnapshot()
            try snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
            onWrite?(snapshot)
        } catch {
            #if DEBUG
            print("[SnapshotWriter] write failed: \(error)")
            #endif
        }
    }
}
