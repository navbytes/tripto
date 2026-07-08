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

    @State private var displayName = ""
    @State private var toast: String?
    @State private var isPresentingDeleteConfirm = false
    @State private var isDeletingAccount = false

    private var myProfile: Profile? {
        guard let userId = authManager.userId else { return nil }
        return profiles.first { $0.id == userId }
    }

    private var isNameChanged: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (myProfile?.displayName ?? "")
    }

    var body: some View {
        Form {
            Section("Profile") {
                HStack(spacing: Spacing.md) {
                    Circle()
                        .fill(AvatarColor.color(named: myProfile?.avatarColor ?? "slate"))
                        .frame(width: 52, height: 52)
                        .overlay {
                            Text(initials(from: displayName))
                                .font(Typo.display(18))
                                .foregroundStyle(.white)
                        }
                    TextField("Display name", text: $displayName)
                        .font(Typo.body(weight: .semibold))
                }
                .padding(.vertical, Spacing.xs)

                Button("Save changes") { saveDisplayName() }
                    .disabled(!isNameChanged)
            }

            Section {
                Button("Sign out", role: .destructive) {
                    Task { await authManager.signOut() }
                }
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
        .toastOverlay($toast)
        .onAppear {
            if displayName.isEmpty {
                displayName = myProfile?.displayName ?? ""
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
        // TODO(v1.1): this page doesn't exist yet (CLAUDE.md/M3 brief) — the
        // URL is reserved so the link ships pointed at the right place from
        // day one rather than needing an app update later to add it.
        URL(string: "https://tripto.navbytes.io/privacy")!
    }

    private func saveDisplayName() {
        guard let profile = myProfile else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.displayName else { return }
        profile.displayName = trimmed
        profile.updatedAt = .now
        try? modelContext.save()
        let dto = profile.toDTO()
        let id = profile.id
        Task { await syncEngine?.enqueueUpsert(table: .profiles, rowId: id, tripId: nil, payload: dto) }
        toast = "Name updated"
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
            toast = "Couldn\u{2019}t delete your account \u{2014} try again."
        }
    }
}
