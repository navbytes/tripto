import Foundation
import Supabase
import UserNotifications

// MARK: - Pure (unit tested — see SuggestionAlertsTests)

/// EI-5 / ROADMAP 3.3: the Settings "Suggestion alerts" toggle's whole
/// contract — request permission, register for APNs, upsert/delete the
/// `device_tokens` row (T2 decisions, `.claude/company/release-prep-push/
/// BRIEF.md`: own-row RLS, no register-device function, "Settings toggle =
/// local permission + token row lifecycle, no row = no push"). Split the
/// same way `LiveActivityCoordinator` is: pure decision logic first (this
/// enum + `SuggestionAlertsToggle`'s pure functions below), side effects
/// (APNs/network, exercised live) further down.
enum SuggestionAlertsOutcome: Equatable {
    case authorized(tokenHex: String)
    case denied
    case registrationFailed
}

enum SuggestionAlertsToggle {
    /// `nil` for `.authorized` — no toast; the toggle just stays on, same
    /// "just flips" precedent this screen's other device-local toggle
    /// ("Show past trips") already sets. The other two branches are §6.6
    /// "what happened + how to fix it": `.denied` names the actual fix;
    /// `.registrationFailed` — today, always, since the App ID has no Push
    /// capability yet (CRITICAL CONSTRAINT, T2 BRIEF) — never blames the
    /// user for something only a future build can fix.
    static func failureMessage(for outcome: SuggestionAlertsOutcome) -> String? {
        switch outcome {
        case .authorized:
            return nil
        case .denied:
            return "Notifications are off. Turn them on in Settings \u{2192} Tripto to get suggestion alerts."
        case .registrationFailed:
            return "Couldn\u{2019}t turn on notifications on this build."
        }
    }

    /// Only a real `.authorized` result earns the on state — both failure
    /// branches revert the toggle rather than leaving it on with no token
    /// backing it (which would silently just never notify).
    static func shouldRevertToOff(for outcome: SuggestionAlertsOutcome) -> Bool {
        if case .authorized = outcome { return false }
        return true
    }
}

// MARK: - Side effects (APNs + device_tokens; exercised live, not unit tested)

extension SuggestionAlertsToggle {
    /// Hermetic UI tests (`-uitestAutoSignIn`) must never trigger a real
    /// system permission prompt (nothing in automation can dismiss it) or a
    /// real APNs round-trip — same guard shape `AuthManager.init`'s
    /// synthetic-session path already uses.
    private static var isHermeticUITest: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uitestAutoSignIn")
        #else
        return false
        #endif
    }

    /// `SettingsView`'s toggle turning ON — the one moment this app ever
    /// shows the system notification-permission prompt.
    static func enable(userId: UUID?) async -> SuggestionAlertsOutcome {
        guard !isHermeticUITest else { return .registrationFailed }
        guard let userId else { return .registrationFailed }
        let granted: Bool
        do {
            granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return .registrationFailed
        }
        guard granted else { return .denied }
        return await registerAndUpload(userId: userId)
    }

    /// Sign-in's best-effort reupload (`AuthManager.completeSignInWithApple`):
    /// never requests authorization (only `enable` above ever prompts) —
    /// only refreshes a token this device is already authorized for, so a
    /// user switching accounts on one device re-associates their existing
    /// token with the new `user_id` instead of leaving it pointed at the
    /// account they just signed out of.
    static func silentlyRefreshToken(userId: UUID) async -> SuggestionAlertsOutcome {
        guard !isHermeticUITest else { return .registrationFailed }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return .denied }
        return await registerAndUpload(userId: userId)
    }

    private static func registerAndUpload(userId: UUID) async -> SuggestionAlertsOutcome {
        guard let delegate = await PushDelegate.shared else { return .registrationFailed }
        switch await delegate.registerForRemoteNotifications() {
        case .success(let deviceToken):
            let tokenHex = PushTokenEncoding.hexString(deviceToken)
            await uploadToken(tokenHex, userId: userId)
            return .authorized(tokenHex: tokenHex)
        case .failure:
            // No `aps-environment` entitlement yet (CRITICAL CONSTRAINT) is
            // the expected failure today — `didFailToRegisterForRemoteNotifications`
            // fires immediately, no network involved either way.
            return .registrationFailed
        }
    }

    private struct DeviceTokenUpsert: Encodable {
        let userId: UUID
        let token: String
        let updatedAt: Date
    }

    /// `device_tokens`' primary key is `(user_id, token)` — composite, not
    /// `user_id` alone (backend migration, T2-migration.md handoff) — so an
    /// account can hold more than one device's row at once. Caches the hex
    /// on success so `disable()` below can scope its delete to *this*
    /// device's own row rather than every row this `user_id` has.
    private static func uploadToken(_ tokenHex: String, userId: UUID) async {
        do {
            try await Supa.client.from("device_tokens")
                .upsert(DeviceTokenUpsert(userId: userId, token: tokenHex, updatedAt: .now), returning: .minimal)
                .execute()
            SuggestionAlertsPreference.lastUploadedTokenHex = tokenHex
        } catch {
            // Best-effort, same contract as `AuthManager.linkAppleTokenBestEffort`
            // — a failed upload just means no push until the next successful
            // one; never surfaced as a toggle failure since APNs registration
            // itself (the part the user can act on) already succeeded.
        }
    }

    /// `SettingsView`'s toggle turning OFF, and step one of
    /// `AuthManager.signOut()` (`AuthManager.signOutSequence`) — best-effort,
    /// same reasoning as `uploadToken` above: a failed delete just leaves a
    /// harmless stale row (a later upsert overwrites it), never blocks the
    /// toggle or sign-out itself. Guarded like `enable`/`silentlyRefreshToken`
    /// above — `signOut()`'s real "Sign out" button is always reachable, so a
    /// hermetic UI test tapping it must not fire this network call either.
    ///
    /// Scoped to `user_id` **and** this device's own cached token (composite
    /// PK — see `uploadToken` above): without the token half, this would
    /// delete every device this account has ever registered, not just the
    /// one signing out/toggling off here. No cached token (never uploaded
    /// from this install) means nothing here to clean up — a no-op, not a
    /// user_id-only delete.
    static func disable(userId: UUID?) async {
        guard !isHermeticUITest else { return }
        guard let userId, let tokenHex = SuggestionAlertsPreference.lastUploadedTokenHex else { return }
        do {
            try await Supa.client.from("device_tokens").delete()
                .eq("user_id", value: userId).eq("token", value: tokenHex).execute()
            SuggestionAlertsPreference.lastUploadedTokenHex = nil
        } catch {
            // Swallowed by design — see the doc comment above. Leaves the
            // cache in place (rather than clearing unconditionally) so a
            // later retry — toggling off again, or a future sign-out — can
            // still target the same row.
        }
    }
}

// MARK: - Local preference (device-local `@AppStorage`, SettingsView.swift's
// "Show past trips" toggle precedent)

enum SuggestionAlertsPreference {
    static let appStorageKey = "suggestionAlertsEnabled"
    private static let tokenHexKey = "suggestionAlertsTokenHex"

    /// `AuthManager` isn't a View and so can't hold `@AppStorage` itself —
    /// reads the identical key `SettingsView`'s toggle binds, so the two can
    /// never drift apart on a typo'd string literal (same reasoning as
    /// `HomePastTripsVisibility.appStorageKey`).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: appStorageKey)
    }

    /// This device's own last-successfully-uploaded token hex —
    /// `SuggestionAlertsToggle.disable`'s only way to scope a delete to its
    /// own `device_tokens` row (composite PK `(user_id, token)`) rather than
    /// every device this account has registered. Plain `UserDefaults`, not
    /// Keychain: a push token is an opaque routing handle, not a secret
    /// (same reasoning `device_tokens`' own-row-not-deny-all RLS uses, T2
    /// decisions).
    static var lastUploadedTokenHex: String? {
        get { UserDefaults.standard.string(forKey: tokenHexKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenHexKey) }
    }
}

// MARK: - Token/payload parsing (unit tested)

enum PushTokenEncoding {
    /// APNs hands back a raw `Data` device token; `device_tokens.token` is
    /// hex text (T2 decisions) — same `%02x` idiom `AuthManager.sha256`
    /// already uses for its own hex output.
    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

enum PushPayload {
    /// The frozen push payload contract (T2 decisions): `userInfo` carries
    /// `tripId` as a uuid string; alert title/body are composed
    /// server-side, nothing else here reads. Mirrors `DeepLink.tripId(from
    /// url:)`'s "parse the one shape this app cares about, nil for anything
    /// else" style.
    static func tripId(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let raw = userInfo["tripId"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}
