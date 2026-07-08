import AuthenticationServices
import SwiftUI

/// Auth gate's signed-out state (RootView). Production path is Sign in
/// with Apple; DEBUG builds add an anonymous test path since the backend
/// has anonymous sign-ins enabled specifically to unblock development (M1
/// brief's "Backend facts").
struct WelcomeView: View {
    @Environment(AuthManager.self) private var authManager
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

                Spacer()

                VStack(spacing: Spacing.md) {
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
            #endif
        }
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
            Task {
                do {
                    try await authManager.completeSignInWithApple(idToken: idToken)
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
