import SwiftData
import SwiftUI

/// Settings + account deletion (M3 brief; Apple 5.1.1(v)). Reached via
/// `SettingsRoute` pushed onto the shared `NavigationStack` from
/// `HomeView`'s avatar tap.
struct SettingsView: View {
    @Query private var profiles: [Profile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    /// UX audit finding 9: the signed-in user's own avatar color, editable
    /// here with the same four-swatch picker `TripProfileFormSheet` already
    /// offers for non-app profiles — previously fixed/seeded with no way to
    /// change it, the one asymmetry between "my own avatar" and "a kid's/
    /// grandparent's avatar" as the same conceptual object.
    @State private var avatarColor = ""
    @State private var toast: String?
    @State private var isPresentingDeleteConfirm = false
    @State private var isDeletingAccount = false
    /// UX audit finding 1: sign-out now goes through a confirmation instead
    /// of firing on the first tap — see `signOutMessage` for why it also
    /// names any not-yet-synced changes that would be lost.
    @State private var isPresentingSignOutConfirm = false
    /// F2: surfaced when `saveDisplayName()`'s `modelContext.save()` throws,
    /// mirroring `TripFormView`'s `saveError` — the old `try?` silently
    /// claimed success ("Name updated") even on a failed write.
    @State private var nameSaveError: String?
    /// F3: gates the "Discard changes?" dialog on the custom back button
    /// below, since this screen is pushed (not sheet-presented) and so can't
    /// use `interactiveDismissDisabled`/`SheetDismissAttemptObserver`.
    @State private var showDiscardConfirm = false

    private var myProfile: Profile? {
        guard let userId = authManager.userId else { return nil }
        return profiles.first { $0.id == userId }
    }

    private var isNameChanged: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (myProfile?.displayName ?? "")
    }

    /// UX audit finding 9: color-only edits also need a "Save changes"
    /// affordance and the same dirty-form protection the name field already
    /// has — `isProfileChanged` is `isNameChanged` widened to cover either
    /// field.
    private var isColorChanged: Bool {
        !avatarColor.isEmpty && avatarColor != (myProfile?.avatarColor ?? "")
    }

    private var isProfileChanged: Bool { isNameChanged || isColorChanged }

    var body: some View {
        Form {
            Section("Profile") {
                HStack(spacing: Spacing.md) {
                    Circle()
                        .fill(AvatarColor.color(named: avatarColor.isEmpty ? "slate" : avatarColor))
                        .frame(width: 52, height: 52)
                        .overlay {
                            Text(initials(from: displayName))
                                .font(Typo.display(18))
                                .foregroundStyle(.white)
                        }
                    TextField("Display name", text: $displayName)
                        .font(Typo.body(weight: .semibold))
                        .disabled(isDeletingAccount)
                }
                .padding(.vertical, Spacing.xs)

                // UX audit finding 9: same `AvatarColorPicker`
                // `TripProfileFormSheet` uses for a non-app profile — the
                // signed-in user's own avatar was the one avatar in the app
                // with no way to recolor it.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Avatar color")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.slate)
                    AvatarColorPicker(selection: $avatarColor)
                }
                .disabled(isDeletingAccount)
                .opacity(isDeletingAccount ? 0.5 : 1)

                if isProfileChanged {
                    Button("Save changes") { saveProfile() }
                        .disabled(isDeletingAccount)
                }

                if let nameSaveError {
                    Text(nameSaveError)
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.rose)
                }
            }

            Section("Account") {
                if let email = authManager.session?.user.email, !email.isEmpty {
                    LabeledContent("Signed in as", value: email)
                } else {
                    LabeledContent("Account", value: "Signed in")
                }
                // UX audit finding 6: no longer `.destructive` — sign-out is
                // a reversible session end, not data loss, so it shouldn't
                // read identically to "Delete account" below. Finding 1:
                // routes through a confirmation instead of firing instantly.
                Button("Sign out") {
                    isPresentingSignOutConfirm = true
                }
                .disabled(isDeletingAccount)
            }

            Section {
                Button(role: .destructive) {
                    isPresentingDeleteConfirm = true
                } label: {
                    if isDeletingAccount {
                        HStack {
                            ProgressView()
                            Text("Deleting account\u{2026}")
                        }
                    } else {
                        Text("Delete account")
                    }
                }
                .disabled(isDeletingAccount)
            } footer: {
                Text("This permanently deletes your account and any trips you created.")
                    .font(Typo.body(Typo.Size.caption))
            }

            Section("About") {
                LabeledContent("Version", value: appVersionString)
                Link("Privacy policy", destination: privacyURL)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Fonts")
                        .font(Typo.body(weight: .semibold))
                    Text("Fraunces and Sofia Sans are used under the SIL Open Font License 1.1.")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // F3: this screen is pushed onto the shared `NavigationStack`
        // (`SettingsRoute`), not sheet-presented, so the default back
        // button is replaced with a custom one below that can intercept a
        // dirty display-name edit before it's silently discarded.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: backTapped) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                        Text("Back")
                    }
                }
                .disabled(isDeletingAccount)
            }
        }
        .toastOverlay($toast)
        .onAppear {
            if displayName.isEmpty {
                displayName = myProfile?.displayName ?? ""
            }
            if avatarColor.isEmpty {
                avatarColor = myProfile?.avatarColor ?? ""
            }
        }
        // Covers a brand-new sign-in: `myProfile` can still be nil at
        // `.onAppear` (the first `pullHome()` hasn't landed yet) — this
        // fills the field reactively the moment it arrives, but only while
        // the field is still untouched, so it never clobbers something the
        // user already started typing.
        .onChange(of: myProfile?.displayName) { _, newValue in
            if displayName.isEmpty, let newValue {
                displayName = newValue
            }
        }
        // UX audit finding 9: same reactive fill as the name field above,
        // for the same brand-new-sign-in race.
        .onChange(of: myProfile?.avatarColor) { _, newValue in
            if avatarColor.isEmpty, let newValue {
                avatarColor = newValue
            }
        }
        // F2: clears a stale write-failure caption the moment the user
        // edits the field again, same as `TripFormView`'s `isClearedByEditing`.
        .onChange(of: displayName) { _, _ in
            if nameSaveError != nil {
                nameSaveError = nil
            }
        }
        .onChange(of: avatarColor) { _, _ in
            if nameSaveError != nil {
                nameSaveError = nil
            }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isPresentingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes your account and any trips you created. "
                    + "Trips you were invited to will lose you as a member. This can\u{2019}t be undone."
            )
        }
        .confirmationDialog(
            "Sign out?",
            isPresented: $isPresentingSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task { await authManager.signOut() }
            }
            Button("Keep me signed in", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private func backTapped() {
        if isProfileChanged {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    /// F1: names the actual consequence of signing out — restores the
    /// protection commit e8f2722 added for permanently-failed syncs
    /// (`syncIssues`), which an unconfirmed sign-out used to drop silently
    /// alongside any still-queued (`pendingCount`) changes.
    private var signOutMessage: String {
        let unsynced = syncStatus.pendingCount + syncStatus.syncIssues.count
        guard unsynced > 0 else {
            return "You\u{2019}ll need to sign in again to see your trips on this device."
        }
        let changeWord = unsynced == 1 ? "change" : "changes"
        return "You have \(unsynced) \(changeWord) that haven\u{2019}t synced yet. Signing out will permanently " +
            "discard them \u{2014} sign in again first to let them sync."
    }

    private func initials(from name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return first.isEmpty ? "?" : first.prefix(1).uppercased()
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = info?["CFBundleVersion"] as? String ?? "\u{2014}"
        return "\(version) (\(build))"
    }

    private var privacyURL: URL {
        // Served live by the share Worker (web/share-worker/src/index.ts:
        // GET /privacy -> renderPrivacyPage, HTTP 200).
        URL(string: "https://tripto.navbytes.io/privacy")!
    }

    /// UX audit finding 9: widened from the original `saveDisplayName()` to
    /// also persist a changed `avatarColor` — one save affordance for both
    /// fields in the Profile section, same as `TripProfileFormSheet`'s
    /// single "Save changes" covering its name+color pair.
    private func saveProfile() {
        guard let profile = myProfile else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !trimmed.isEmpty && trimmed != profile.displayName
        let colorChanged = !avatarColor.isEmpty && avatarColor != profile.avatarColor
        guard nameChanged || colorChanged else { return }
        nameSaveError = nil
        if nameChanged { profile.displayName = trimmed }
        if colorChanged { profile.avatarColor = avatarColor }
        profile.updatedAt = .now
        // F2: mirrors `TripFormView`'s F6 do/catch — a failed write used to
        // still claim "Name updated" via a silent `try?`. Signed-out edits
        // need no extra guard here: `myProfile` is keyed on
        // `authManager.userId`, so it's already nil (and the guard above
        // already returned) the moment the user signs out.
        do {
            try modelContext.save()
        } catch {
            nameSaveError = "Couldn\u{2019}t save your changes. Try again."
            return
        }
        let dto = profile.toDTO()
        let id = profile.id
        Task { await syncEngine?.enqueueUpsert(table: .profiles, rowId: id, tripId: nil, payload: dto) }
        toast = nameChanged && colorChanged ? "Profile updated" : (nameChanged ? "Name updated" : "Avatar color updated")
    }

    /// Apple 5.1.1(v) account deletion. Routes through the `delete-account`
    /// edge function, which first best-effort-revokes the user's Apple token
    /// via Apple's REST API (Sign in with Apple's additional contract) and then
    /// deletes the `auth.users` row — cascading to this user's profile, owned
    /// trips, memberships, packing, and the stored Apple refresh token. A
    /// revoke hiccup never blocks deletion (data deletion always proceeds), and
    /// if the Apple key secret isn't configured the function simply skips the
    /// revoke and still deletes. Returns 204 on success.
    private func deleteAccount() async {
        isDeletingAccount = true
        do {
            try await Supa.client.functions.invoke("delete-account")
            await authManager.signOut()
            // No further UI work needed: `signOut()` wipes the local store
            // and clears the session, and `RootView`'s auth gate switches
            // to `WelcomeView` the moment `isSignedIn` flips false — tearing
            // down this whole pushed screen along with it.
        } catch {
            isDeletingAccount = false
            // F5: names the actual cause instead of one generic retry
            // message for every failure (§6.6) — a dropped connection and a
            // server-side failure call for different next steps.
            if error is URLError {
                toast = "You\u{2019}re offline \u{2014} reconnect and try deleting again."
            } else {
                toast = "Something went wrong on our end deleting your account. Try again in a moment."
            }
        }
    }
}
