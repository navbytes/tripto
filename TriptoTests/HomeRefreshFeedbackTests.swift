import XCTest
@testable import Tripto

/// `HomeRefreshFeedback.shouldToastAfterRefresh` (UX audit finding 1's
/// refresh-scoped gap) — the regression net for the toast-gating decision,
/// mirroring `HomeEmptyPlaceholderTests`' style.
final class HomeRefreshFeedbackTests: XCTestCase {
    func testFailedOnlineWithTripsShowsToast() {
        // The finding's headline scenario: flaky hotel Wi-Fi, populated list.
        let result = HomeRefreshFeedback.shouldToastAfterRefresh(
            lastHomePullFailed: true,
            isOffline: false,
            hasTrips: true
        )
        XCTAssertTrue(result)
    }

    func testFailedOfflineWithTripsSuppressesToast() {
        // `SyncBanner` already owns communicating the offline state.
        let result = HomeRefreshFeedback.shouldToastAfterRefresh(
            lastHomePullFailed: true,
            isOffline: true,
            hasTrips: true
        )
        XCTAssertFalse(result)
    }

    func testFailedOnlineEmptySuppressesToast() {
        // `HomeEmptyPlaceholder`'s `pullFailedState` already owns this case.
        let result = HomeRefreshFeedback.shouldToastAfterRefresh(
            lastHomePullFailed: true,
            isOffline: false,
            hasTrips: false
        )
        XCTAssertFalse(result)
    }

    func testNotFailedSuppressesToast() {
        let result = HomeRefreshFeedback.shouldToastAfterRefresh(
            lastHomePullFailed: false,
            isOffline: false,
            hasTrips: true
        )
        XCTAssertFalse(result)
    }

    // MARK: - shouldNoteRetryFailure (finding 1's retry-button note)

    func testRetryFailedOnlineNotes() {
        XCTAssertTrue(
            HomeRefreshFeedback.shouldNoteRetryFailure(lastHomePullFailed: true, isOffline: false)
        )
    }

    func testRetryFailedOfflineSuppressesNote() {
        // `HomeEmptyPlaceholder.resolve` already flips the whole screen to
        // `offlineFirstLoadState` in this case — an inline note would
        // double-signal.
        XCTAssertFalse(
            HomeRefreshFeedback.shouldNoteRetryFailure(lastHomePullFailed: true, isOffline: true)
        )
    }

    func testRetrySucceededOnlineSuppressesNote() {
        XCTAssertFalse(
            HomeRefreshFeedback.shouldNoteRetryFailure(lastHomePullFailed: false, isOffline: false)
        )
    }

    func testRetrySucceededOfflineSuppressesNote() {
        XCTAssertFalse(
            HomeRefreshFeedback.shouldNoteRetryFailure(lastHomePullFailed: false, isOffline: true)
        )
    }
}
