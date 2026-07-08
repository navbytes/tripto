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
            if session != nil {
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
    /// DEBUG-only test path (WelcomeView's "Continue (test account)"
    /// button) — anonymous sign-ins are enabled on the backend specifically
    /// to unblock development (see the M1 brief's backend facts). Compiled out
    /// of Release so the capability isn't even present in the shipped binary.
    func signInAnonymously() async throws {
        _ = try await Supa.client.auth.signInAnonymously()
    }
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
    /// authorization's `identityToken`, decoded as UTF-8.
    func completeSignInWithApple(idToken: String) async throws {
        guard let nonce = pendingAppleNonce else {
            throw AuthManagerError.missingNonce
        }
        pendingAppleNonce = nil
        _ = try await Supa.client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    // MARK: - Sign out

    /// Wipes the local mirror/outbox first (still-authenticated, so this is
    /// a plain local operation), then signs out of Supabase — the order
    /// that leaves no stale rows on screen even if the network call itself
    /// is slow or fails.
    func signOut() async {
        await syncEngine.wipeForSignOut()
        try? await Supa.client.auth.signOut()
    }

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
