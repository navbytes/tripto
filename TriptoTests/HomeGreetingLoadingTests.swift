import XCTest
@testable import Tripto

/// `HomeGreetingLoading.isStillLoading` (P7b award-audit fix) — the
/// regression net for the "redacted skeleton forever" finding: offline with
/// no cached profile must settle to the plain nameless greeting, not loop
/// forever waiting on a pull that can never complete offline.
final class HomeGreetingLoadingTests: XCTestCase {
    func testSignedOutNeverLoading() {
        XCTAssertFalse(HomeGreetingLoading.isStillLoading(
            hasDisplayName: false, isSignedIn: false, hasCompletedInitialHomePull: false, isOffline: false
        ))
    }

    func testHasDisplayNameNeverLoadingRegardlessOfPullState() {
        XCTAssertFalse(HomeGreetingLoading.isStillLoading(
            hasDisplayName: true, isSignedIn: true, hasCompletedInitialHomePull: false, isOffline: false
        ))
    }

    func testOnlineBeforeFirstPullIsLoading() {
        XCTAssertTrue(HomeGreetingLoading.isStillLoading(
            hasDisplayName: false, isSignedIn: true, hasCompletedInitialHomePull: false, isOffline: false
        ))
    }

    func testOnlineAfterFirstPullSettlesNameless() {
        XCTAssertFalse(HomeGreetingLoading.isStillLoading(
            hasDisplayName: false, isSignedIn: true, hasCompletedInitialHomePull: true, isOffline: false
        ))
    }

    /// The finding itself: offline + a first pull that never completed used
    /// to loop forever (`pullHome()` no-ops while offline, so
    /// `hasCompletedInitialHomePull` never flips true) — this now settles
    /// immediately instead, same as `HomeEmptyPlaceholder.resolve`'s own
    /// `.offlineFirstLoad` already treats the same combination.
    func testOfflineBeforeFirstPullSettlesNamelessInsteadOfLoadingForever() {
        XCTAssertFalse(HomeGreetingLoading.isStillLoading(
            hasDisplayName: false, isSignedIn: true, hasCompletedInitialHomePull: false, isOffline: true
        ))
    }

    func testOfflineAfterFirstPullSettlesNameless() {
        XCTAssertFalse(HomeGreetingLoading.isStillLoading(
            hasDisplayName: false, isSignedIn: true, hasCompletedInitialHomePull: true, isOffline: true
        ))
    }
}
