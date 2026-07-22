import AuthenticationServices
import CryptoKit
import Foundation
import Supabase

/// Auth state + the Sign in with Apple nonce dance (SYNC_DESIGN.md "Auth").
/// `RootView` reads `isSignedIn`/`isRestoring` to gate between `WelcomeView`
/// and `HomeView`; nothing else in the app touches `Supa.client.auth`
/// directly.
@Observable
@MainActor
final class AuthManager {
    private(set) var session: Session?
    /// True until the very first `authStateChanges` event (`.initialSession`,
    /// emitted immediately on subscribe) — the brief window before we know
    /// whether a Keychain-persisted session exists. `RootView` should not
    /// flash `WelcomeView` during this.
    private(set) var isRestoring = true

    var isSignedIn: Bool { session != nil }
    var userId: UUID? { session?.user.id }

    private let syncEngine: SyncEngine
    private var authStateTask: Task<Void, Never>?
    private var pendingAppleNonce: String?

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
        #if DEBUG
        // C4/ROADMAP §3.1: `-uitestAutoSignIn` used to call the real
        // `signInAnonymously()`, coupling every UI test run to a production
        // auth setting (and occasionally racing the seed step). Inject a
        // fixed fake session synchronously instead, and skip subscribing to
        // `authStateChanges` entirely — subscribing would still emit a real
        // (or absent) `.initialSession` shortly after and clobber this one.
        if ProcessInfo.processInfo.arguments.contains("-uitestAutoSignIn") {
            session = Self.uitestSession
            isRestoring = false
            Task { [weak self] in
                await self?.syncEngine.start()
            }
            return
        }
        #endif
        authStateTask = Task { [weak self] in
            for await (event, session) in Supa.client.auth.authStateChanges {
                await self?.handle(event: event, session: session)
            }
        }
    }

    private func handle(event: AuthChangeEvent, session: Session?) async {
        self.session = session
        switch event {
        case .initialSession:
            isRestoring = false
            // `emitLocalSessionAsInitialSession: true` (SupabaseClient.swift)
            // means `session` here may be expired — the SDK refreshes it in
            // the background and a later `.tokenRefreshed`/`.signedOut` event
            // updates `self.session` above, but starting the sync engine
            // against a known-expired session would just spend its first
            // requests on 401s.
            if let session, !session.isExpired {
                await syncEngine.start()
            }
        case .signedIn:
            await syncEngine.start()
        default:
            break
        }
    }

    // MARK: - Sign in

    #if DEBUG
    /// Fixed user id for every `-uitestAutoSignIn` launch — `DemoSeeder` and
    /// everything else in the app reads only `AuthManager.userId` (never the
    /// SDK's own session), so the same identity across relaunches within a
    /// test run is all that's needed for local data to stay consistent.
    private static let uitestUserId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    /// A wholly synthetic `Session`/`User` — every field is a fixed literal
    /// (no `Date()`/`.now`) so the session itself can never be a source of
    /// flakiness; `expiresAt` is simply a fixed distant epoch rather than
    /// "far future" measured from now. Never sent over the network: the app
    /// never reaches `Supa.client.auth` in this path, and every UI test also
    /// launches with `-simulateOffline`.
    private static let uitestSession = Session(
        accessToken: "uitest-fixed-access-token",
        tokenType: "bearer",
        expiresIn: 315_360_000, // ~10 years, matches expiresAt below
        expiresAt: 4_102_444_800, // 2100-01-01T00:00:00Z
        refreshToken: "uitest-fixed-refresh-token",
        user: User(
            id: uitestUserId,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            email: "uitest@example.com",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            isAnonymous: true
        )
    )
    #endif

    /// Generates a fresh nonce for one Sign in with Apple attempt and
    /// returns its SHA256 hash, ready for
    /// `ASAuthorizationAppleIDRequest.nonce`. Call this from
    /// `SignInWithAppleButton`'s `onRequest`; the raw nonce is remembered
    /// for the matching `completeSignInWithApple(idToken:)` call.
    func hashedNonceForAppleSignIn() -> String {
        let nonce = Self.randomNonceString()
        pendingAppleNonce = nonce
        return Self.sha256(nonce)
    }

    /// Call from `SignInWithAppleButton`'s `onCompletion` with the
    /// authorization's `identityToken` and one-time `authorizationCode`, both
    /// decoded as UTF-8.
    func completeSignInWithApple(idToken: String, authorizationCode: String?) async throws {
        guard let nonce = pendingAppleNonce else {
            throw AuthManagerError.missingNonce
        }
        pendingAppleNonce = nil
        _ = try await Supa.client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        // Best-effort: hand Apple's one-time authorization code to the backend
        // so it can store a refresh token for token revocation on account
        // deletion (App Store 5.1.1(v), `apple-link-token` edge function). This
        // must NEVER block or fail sign-in — a failure here only means
        // revocation data isn't captured, which the delete flow already
        // tolerates (its Apple revoke step is itself best-effort).
        if let authorizationCode {
            await linkAppleTokenBestEffort(authorizationCode)
        }
        // T2: same "must never block or fail sign-in" contract as the Apple
        // token link above — re-associates this device's already-authorized
        // push token (if any) with the account that just signed in, so
        // switching accounts on one device doesn't leave the token pointed
        // at the previous user.
        await reuploadPushTokenBestEffort()
    }

    private func linkAppleTokenBestEffort(_ authorizationCode: String) async {
        struct Body: Encodable { let authorization_code: String }
        do {
            try await Supa.client.functions.invoke(
                "apple-link-token",
                options: FunctionInvokeOptions(body: Body(authorization_code: authorizationCode))
            )
        } catch {
            // Swallowed by design — see the call site.
        }
    }

    /// T2: never requests authorization (only the Settings toggle does
    /// that) — a no-op unless the user already turned Suggestion alerts on
    /// (`SuggestionAlertsPreference`) and iOS still has this app authorized.
    private func reuploadPushTokenBestEffort() async {
        guard SuggestionAlertsPreference.isEnabled, let userId else { return }
        _ = await SuggestionAlertsToggle.silentlyRefreshToken(userId: userId)
    }

    // MARK: - Sign out

    /// Runs `Self.signOutSequence` in order — the array itself is the
    /// single source of truth for that order (unit-tested directly,
    /// `AuthManagerSignOutSequenceTests`), so the tested order and the real
    /// order can never drift apart.
    func signOut() async {
        let userId = self.userId
        for step in Self.signOutSequence {
            switch step {
            case .deletePushToken:
                // T2: needs the still-live session (RLS is own-row
                // `user_id = auth.uid()`) — must run before both the wipe
                // and the remote sign-out below.
                await SuggestionAlertsToggle.disable(userId: userId)
            case .wipeLocalData:
                // Still-authenticated at this point, so this is a plain
                // local operation.
                await syncEngine.wipeForSignOut()
            case .signOutRemote:
                // Deliberately last — wipe-then-signout leaves no stale
                // rows on screen even if this network call itself is slow
                // or fails.
                try? await Supa.client.auth.signOut()
            }
        }
    }

    static let signOutSequence: [SignOutStep] = [.deletePushToken, .wipeLocalData, .signOutRemote]

    // MARK: - Nonce helpers (Apple's documented SiwA + Supabase recipe)

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with OSStatus \(status)")

        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

enum AuthManagerError: Error {
    case missingNonce
}

/// The three steps `AuthManager.signOut()` runs, in order — pulled out as a
/// pure, order-only value (T2: "token row delete must happen BEFORE
/// wipe/logout") so that constraint is unit-testable without a real
/// `Supa.client`/`SyncEngine`.
enum SignOutStep: Equatable {
    case deletePushToken
    case wipeLocalData
    case signOutRemote
}
