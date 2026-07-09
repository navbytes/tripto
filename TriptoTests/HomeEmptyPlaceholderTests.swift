import XCTest
@testable import Tripto

/// `HomeEmptyPlaceholder.resolve` (UX audit finding 1) — the regression net
/// for both the new pull-failed state and the previously-fixed findings its
/// decision table also encodes (initial-load vs. genuinely-empty, offline
/// first load, joining priority). Land these before `HomeView`'s rewiring
/// depends on the resolver.
final class HomeEmptyPlaceholderTests: XCTestCase {
    func testFirstMountOnlineShowsInitialLoad() {
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: false,
            hasCompletedInitialHomePull: false,
            lastHomePullFailed: false,
            isOffline: false
        )
        XCTAssertEqual(result, .initialLoad)
    }

    func testFirstPullFailedOnlineShowsPullFailed() {
        // The finding: a failed first pull must not be misread as "plan
        // your first trip."
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: false,
            hasCompletedInitialHomePull: true,
            lastHomePullFailed: true,
            isOffline: false
        )
        XCTAssertEqual(result, .pullFailed)
    }

    func testFailedThenWentOfflineShowsOfflineFirstLoad() {
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: false,
            hasCompletedInitialHomePull: true,
            lastHomePullFailed: true,
            isOffline: true
        )
        XCTAssertEqual(result, .offlineFirstLoad)
    }

    func testOfflineLaunchBeforeFirstPullShowsOfflineFirstLoad() {
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: false,
            hasCompletedInitialHomePull: false,
            lastHomePullFailed: false,
            isOffline: true
        )
        XCTAssertEqual(result, .offlineFirstLoad)
    }

    func testGenuinelyEmptyAccountShowsEmpty() {
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: false,
            hasCompletedInitialHomePull: true,
            lastHomePullFailed: false,
            isOffline: false
        )
        XCTAssertEqual(result, .empty)
    }

    func testJoiningTripOnlineTakesPriority() {
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: true,
            hasCompletedInitialHomePull: true,
            lastHomePullFailed: false,
            isOffline: false
        )
        XCTAssertEqual(result, .joining)
    }

    func testJoiningTripOfflineTakesPriority() {
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: true,
            hasCompletedInitialHomePull: false,
            lastHomePullFailed: false,
            isOffline: true
        )
        XCTAssertEqual(result, .joining)
    }

    func testPostSuccessBackgroundPullFailureShowsPullFailed() {
        // hasCompletedInitialHomePull was already true from an earlier
        // success; a later background pull (e.g. pull-to-refresh) fails.
        let result = HomeEmptyPlaceholder.resolve(
            isJoiningTrip: false,
            hasCompletedInitialHomePull: true,
            lastHomePullFailed: true,
            isOffline: false
        )
        XCTAssertEqual(result, .pullFailed)
    }
}
