import XCTest
@testable import Tripto

/// T2: "token row delete must happen BEFORE wipe/logout (needs the live
/// session)" — `AuthManager.signOut()` is literally driven by
/// `AuthManager.signOutSequence` (see that property's own doc comment), so
/// pinning this array's order is the whole test; there's no real
/// `Supa.client`/`SyncEngine` to seam/mock.
final class AuthManagerSignOutSequenceTests: XCTestCase {
    func testDeletesPushTokenBeforeWipeAndRemoteSignOut() {
        XCTAssertEqual(AuthManager.signOutSequence, [.deletePushToken, .wipeLocalData, .signOutRemote])
    }
}
