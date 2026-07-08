import AuthenticationServices
import SwiftUI

/// Auth gate's signed-out state (RootView). Production path is Sign in
/// with Apple; DEBUG builds add an anonymous test path since the backend
/// has anonymous sign-ins enabled specifically to unblock development (M1
/// brief's "Backend facts").
struct WelcomeView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(AppRouter.self) private var appRouter
    @State private var errorMessage: String?
    @State private var isSigningInAnonymously = false

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(spacing: Spacing.xxl) {
                Spacer()

                VStack(spacing: Spacing.sm) {
                    Text("Tripto")
                        .font(Typo.display(48))
                        .foregroundStyle(Palette.ink)
                    Text("Everyone's plans, one shared itinerary.")
                        .font(Typo.body())
                        .foregroundStyle(Palette.slate)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.xl)

                invitePreviewCard

                Spacer()

                VStack(spacing: Spacing.md) {
                    if appRouter.pendingInvitePreview != nil {
                        Text("Sign in to join")
                            .font(Typo.body(Typo.Size.caption, weight: .semibold))
                            .foregroundStyle(Palette.slate)
                    }
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = authManager.hashedNonceForAppleSignIn()
                    } onCompletion: { result in
                        handleAppleCompletion(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))

                    #if DEBUG
                    Button {
                        Task { await signInAnonymously() }
                    } label: {
                        HStack {
                            if isSigningInAnonymously {
                                ProgressView().tint(Palette.ink)
                            }
                            Text("Continue (test account)")
                        }
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .background(Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                    .disabled(isSigningInAnonymously)
                    #endif

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(Palette.slate)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
            }
        }
        .task {
            #if DEBUG
            // M2 verify-drill autopilot (docs/BUILD_PLAN.md milestone
            // process, not a shipped feature): a plain launch argument, so
            // the simulator drill can reach a signed-in state with no GUI
            // tap automation available in this environment. Never fires
            // without the flag, so normal launches are unaffected.
            if ProcessInfo.processInfo.arguments.contains("-uitestAutoSignIn") {
                await signInAnonymously()
            }
            // Injects a mock invite preview so the pre-sign-in invite card can be
            // screenshotted without a live two-user invite flow.
            if ProcessInfo.processInfo.arguments.contains("-uitestInvitePreview") {
                appRouter.debugInjectInvitePreview(
                    InvitePreview(role: "companion", tripTitle: "Lisbon", startDate: "2026-05-14",
                                  endDate: "2026-05-27", coverGradient: "dusk", inviterName: "Meera")
                )
            }
            #endif
        }
    }

    /// Shown while an invite link is pending and its `peek_invite` preview has
    /// loaded — so you see who invited you, which trip, and what role BEFORE
    /// handing Apple your identity (usability dry-run).
    @ViewBuilder
    private var invitePreviewCard: some View {
        if let preview = appRouter.pendingInvitePreview {
            let role = TripRole(rawValue: preview.role)
            VStack(spacing: Spacing.xs) {
                Text("You\u{2019}re invited")
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.amber)
                    .tracking(0.4)
                    .textCase(.uppercase)
                Text("\(preview.inviterName) invited you to")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                Text(preview.tripTitle)
                    .font(Typo.display(Typo.Size.title))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text(dateRange(preview))
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                if let role {
                    Text("Joining as \(role.rawValue.capitalized) \u{00B7} \(role.inviteGrant)")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.indigo)
                        .multilineTextAlignment(.center)
                        .padding(.top, Spacing.xxs)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.lg)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .stroke(Palette.amber.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, Spacing.xl)
        }
    }

    private func dateRange(_ preview: InvitePreview) -> String {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone(identifier: "UTC")
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        out.timeZone = TimeZone(identifier: "UTC")
        guard let start = iso.date(from: preview.startDate), let end = iso.date(from: preview.endDate) else {
            return "\(preview.startDate) \u{2013} \(preview.endDate)"
        }
        return "\(out.string(from: start)) \u{2013} \(out.string(from: end))"
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = "Sign in with Apple didn't return a usable credential — try again."
                return
            }
            // Apple's one-time authorization code (nil if Apple omits it). Used
            // only to enable token revocation on account deletion; sign-in never
            // depends on it.
            let authorizationCode = credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            Task {
                do {
                    try await authManager.completeSignInWithApple(idToken: idToken, authorizationCode: authorizationCode)
                    errorMessage = nil
                } catch {
                    errorMessage = "Sign in with Apple failed — try again."
                }
            }
        case .failure(let error):
            let nsError = error as NSError
            // A user-initiated cancel isn't an error worth surfacing.
            if nsError.code != ASAuthorizationError.canceled.rawValue {
                errorMessage = "Sign in with Apple failed — try again."
            }
        }
    }

    #if DEBUG
    private func signInAnonymously() async {
        isSigningInAnonymously = true
        defer { isSigningInAnonymously = false }
        do {
            try await authManager.signInAnonymously()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start a test session — try again."
        }
    }
    #endif
}
