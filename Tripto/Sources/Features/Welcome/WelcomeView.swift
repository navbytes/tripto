import AuthenticationServices
import SwiftUI

/// Auth gate's signed-out state (RootView). Production path is Sign in
/// with Apple; DEBUG builds add an anonymous test path since the backend
/// has anonymous sign-ins enabled specifically to unblock development (M1
/// brief's "Backend facts").
struct WelcomeView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(AppRouter.self) private var appRouter
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorMessage: String?
    @State private var isSigningInAnonymously = false
    @State private var isCompletingAppleSignIn = false

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            // Accessibility sizes / SE-class screens can make the fixed
            // Spacer-based layout below overflow the screen — a
            // GeometryReader-pinned ScrollView keeps it pixel-identical at
            // default type sizes (the Spacers still expand to fill
            // `geo.size.height`) while letting it scroll when it doesn't fit.
            GeometryReader { geo in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
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
            // Injects a mock invite preview so the pre-sign-in invite card can
            // be screenshotted without a live two-user invite flow.
            if ProcessInfo.processInfo.arguments.contains("-uitestInvitePreview") {
                appRouter.debugInjectInvitePreview(
                    InvitePreview(role: "companion", tripTitle: "Lisbon", startDate: "2026-05-14",
                                  endDate: "2026-05-27", coverGradient: "dusk", inviterName: "Meera")
                )
            }
            #endif
        }
        // A sign-in failure needs to reach VoiceOver even though the error
        // text renders below the fold at some type sizes.
        .onChange(of: errorMessage) { _, newValue in
            if let newValue {
                AccessibilityNotification.Announcement(newValue).post()
            }
        }
    }

    private var content: some View {
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
                if appRouter.pendingInviteToken != nil {
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
                // Apple's Sign in with Apple button has no adaptive style to
                // reuse — the HIG wants white-on-dark / black-on-light, and
                // this isn't a `Palette` member, so it's the one legitimate
                // `colorScheme` branch (the no-branching rule governs
                // `Palette` call sites, not this).
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .disabled(isCompletingAppleSignIn)
                .opacity(isCompletingAppleSignIn ? 0.6 : 1)

                if isCompletingAppleSignIn {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                        Text("Signing you in\u{2026}")
                    }
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                }

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
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.rose)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
    }

    /// Renders `appRouter.invitePreviewState` honestly at every step — the
    /// usability dry-run found the invite -> Sign in with Apple handshake
    /// blind, with no sign of who invited you, which trip, or what role
    /// before handing Apple your identity, and no feedback while the
    /// preview was loading or if it never arrived.
    @ViewBuilder
    private var invitePreviewCard: some View {
        Group {
            switch appRouter.invitePreviewState {
            case .idle:
                EmptyView()
            case .loading:
                invitePreviewChrome(borderColor: Palette.amber.opacity(0.3)) {
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                        Text("Checking your invite\u{2026}")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(Palette.slate)
                    }
                }
            case .loaded(let preview):
                loadedInviteCard(preview)
            case .invalid:
                invitePreviewChrome(borderColor: Palette.rose.opacity(0.3)) {
                    VStack(spacing: Spacing.xs) {
                        Text("Invite link expired")
                            .font(Typo.body(Typo.Size.caption, weight: .bold))
                            .foregroundStyle(Palette.rose)
                        Text("This invite link has expired or been revoked. Ask for a new link.")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(Palette.slate)
                            .multilineTextAlignment(.center)
                    }
                }
            case .unavailable:
                invitePreviewChrome(borderColor: Palette.slate.opacity(0.2)) {
                    Text("Couldn\u{2019}t load your invite details \u{2014} you can still sign in to join.")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                        .multilineTextAlignment(.center)
                }
            }
        }
        // Opacity-only so it's reduced-motion-safe; the loaded card no
        // longer just pops in once the preview resolves.
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: appRouter.invitePreviewState)
    }

    private func loadedInviteCard(_ preview: InvitePreview) -> some View {
        let role = TripRole(rawValue: preview.role)
        return invitePreviewChrome(borderColor: Palette.amber.opacity(0.3)) {
            VStack(spacing: Spacing.xs) {
                Text("You\u{2019}re invited")
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.amberInk)
                    .tracking(0.4)
                    .textCase(.uppercase)
                Text("\(preview.inviterName) invited you to")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                Text(preview.tripTitle)
                    .font(Typo.display(Typo.Size.title))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text(InvitePreview.formattedDateRange(startDate: preview.startDate, endDate: preview.endDate))
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                if let role {
                    Text("Joining as \(role.rawValue.capitalized) \u{00B7} \(role.inviteeGrant)")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, Spacing.xxs)
                }
            }
        }
    }

    /// Shared card chrome for every `invitePreviewCard` state, so
    /// loading/loaded/invalid/unavailable only differ in their inner content
    /// and accent, not their shape.
    private func invitePreviewChrome<Content: View>(
        borderColor: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(Spacing.lg)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .padding(.horizontal, Spacing.xl)
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
                isCompletingAppleSignIn = true
                defer { isCompletingAppleSignIn = false }
                do {
                    try await authManager.completeSignInWithApple(idToken: idToken, authorizationCode: authorizationCode)
                    errorMessage = nil
                } catch {
                    errorMessage = Self.signInFailureMessage(for: error)
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

    /// Distinguishes "you're offline" from every other failure so the copy
    /// tells you what happened and how to fix it (BUILD_PLAN §6.6), rather
    /// than one generic message covering both.
    private static func signInFailureMessage(for error: Error) -> String {
        isOffline(error)
            ? "You\u{2019}re offline \u{2014} connect to the internet and try again."
            : "Couldn\u{2019}t finish signing in \u{2014} check your connection and try again."
    }

    /// Mirrors `AppRouter.isInvalidInvite`'s type-then-string-fallback
    /// idiom: `URLError` is the common case, with the raw `NSURLErrorDomain`
    /// check as a fallback in case an underlying network failure surfaces
    /// wrapped in a different `Error` type.
    private static func isOffline(_ error: Error) -> Bool {
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
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
