import AuthenticationServices
import SwiftUI
import UIKit

/// Auth gate's signed-out state (RootView). The only sign-in path is Sign
/// in with Apple — the former DEBUG-only anonymous test path is gone
/// (backend anon sign-ins are disabled in production, RELEASE_READINESS.md;
/// `-uitestAutoSignIn` now injects a fake session directly in
/// `AuthManager.init`, BACKLOG.md C4, before this view ever mounts).
struct WelcomeView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(AppRouter.self) private var appRouter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var errorMessage: String?
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
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // A sign-in failure needs to reach VoiceOver even though
                    // the error text renders below the fold at some type
                    // sizes — it also fires an error haptic and scrolls the
                    // message into view for sighted users.
                    .onChange(of: errorMessage) { _, newValue in
                        if let newValue {
                            AccessibilityNotification.Announcement(newValue).post()
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            // The conditional Label doesn't exist in the
                            // hierarchy yet when .onChange fires — one tick
                            // lets it get inserted before we scroll to it.
                            Task { @MainActor in
                                await Task.yield()
                                if reduceMotion {
                                    proxy.scrollTo(Self.signInErrorScrollID, anchor: .bottom)
                                } else {
                                    withAnimation {
                                        proxy.scrollTo(Self.signInErrorScrollID, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            #if DEBUG
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
        // Announces the invite preview's resolved states only — .idle/
        // .loading stay silent so VoiceOver isn't chattering mid-fetch.
        // Retry passes through .loading, so a repeat .unavailable
        // re-announces the same way an identical sign-in failure does.
        .onChange(of: appRouter.invitePreviewState) { _, newValue in
            if let announcement = Self.invitePreviewAnnouncement(for: newValue) {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        // Only the false -> true transition announces: success is signaled
        // by the screen swap and failure by the errorMessage .onChange
        // above, so announcing true -> false here would be redundant.
        .onChange(of: isCompletingAppleSignIn) { _, newValue in
            if newValue {
                AccessibilityNotification.Announcement(Self.signingInStatusText).post()
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
                Text("Everyone\u{2019}s plans, one shared itinerary.")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Spacing.xl)

            invitePreviewCard

            samplePreviewSection

            Spacer()

            VStack(spacing: Spacing.md) {
                if appRouter.pendingInviteToken != nil {
                    Text("Sign in to join")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.slate)
                }
                SignInWithAppleButton(.signIn) { request in
                    // Cleared here (attempt start) rather than only on
                    // success — this also makes an identical repeat failure
                    // re-announce to VoiceOver, since it re-crosses the
                    // nil -> message transition the .onChange below listens for.
                    errorMessage = nil
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
                        Text(Self.signingInStatusText)
                    }
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    .transition(.opacity)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.rose)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                        .id(Self.signInErrorScrollID)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
            // Opacity-only so it's reduced-motion-safe, matching the invite
            // card's own treatment — animates the layout shift these rows'
            // appearance/disappearance causes instead of jumping.
            .animation(.easeInOut(duration: 0.2), value: isCompletingAppleSignIn)
            .animation(.easeInOut(duration: 0.2), value: errorMessage)
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
                        Text("Invite link no longer valid")
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
                    VStack(spacing: Spacing.sm) {
                        Text("Couldn\u{2019}t load your invite details \u{2014} you can still sign in to join.")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(Palette.slate)
                            .multilineTextAlignment(.center)
                        Button {
                            appRouter.retryInvitePreview()
                        } label: {
                            Text("Try again")
                                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                                .foregroundStyle(Palette.amberInk)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }
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
                    // `.textCase(.uppercase)` risks an all-caps spell-out
                    // once this is folded into the combined element below.
                    .accessibilityLabel(Text("You\u{2019}re invited"))
                Text("\(preview.inviterName) invited you to")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
                // Title-only cover chip — the invite's one moment to show the
                // trip's actual brand gradient (§6.3) before sign-in. Small
                // text (inviter/dates/role) stays off the gradient on
                // `Palette.elevated` rather than risk contrast on the dark
                // stops; the 0.2 scrim (vs. TripView's 0.08) accounts for
                // this title sitting centered over the gradient's lighter
                // region rather than pinned to its dark corner.
                ZStack {
                    CoverGradient.from(key: preview.coverGradient)
                    Color.black.opacity(0.2)
                    Text(preview.tripTitle)
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, Spacing.md)
                        .frame(maxWidth: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
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
            // Groups the whole card into a single VoiceOver stop (eyebrow ->
            // inviter -> title -> dates -> role, visual order) instead of
            // five separate swipes.
            .accessibilityElement(children: .combine)
        }
    }

    /// Feature A1 (adoption onboarding): a fabricated, in-memory sample
    /// trip rendered through the exact `TripCard` `HomeView` uses for a real
    /// one, so a brand-new signed-out user can feel the product before
    /// creating an account. Deliberately static (no `NavigationLink`/
    /// button) — `TripCard`'s real tap target is wired up by `HomeView`
    /// against its own `@Query`/`AppRouter` navigation stack, none of which
    /// exists pre-sign-in; a tappable read-only itinerary would need to pull
    /// those coupled pieces in just for this one screen, so this stays card
    /// + a short teaser line instead (flagged for design review — see this
    /// change's handoff notes).
    private var samplePreviewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Peek at a sample trip")
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)
                .tracking(0.4)
                .textCase(.uppercase)
                // `.textCase(.uppercase)` risks an all-caps spell-out once
                // this collapses into the combined element below (same
                // reasoning as `loadedInviteCard`'s "You're invited" eyebrow).
                .accessibilityLabel(Text("Sample trip preview"))

            TripCard(trip: SampleTrip.trip, people: SampleTrip.people, isPending: false)

            Text(SampleTrip.teaserText)
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)

            Text("Sign in to make your own")
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, Spacing.xl)
        // One combined VoiceOver stop, "Sample trip preview" always
        // leading — so a screen-reader user can never land on TripCard's
        // own real-trip-shaped label ("Costa Rica with the Crew, in 21
        // days, ...") in isolation and mistake it for an actual trip. This
        // is the quality-bar requirement this pass calls out by name.
        .accessibilityElement(children: .combine)
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
                errorMessage = "Sign in with Apple didn\u{2019}t return a usable credential \u{2014} try again."
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
                } catch {
                    errorMessage = Self.signInFailureMessage(for: error)
                }
            }
        case .failure(let error):
            // A user-initiated cancel isn't an error worth surfacing.
            if !Self.isUserCancelledAppleSignIn(error) {
                errorMessage = Self.appleSideFailureMessage(for: error)
            }
        }
    }

    /// Visible label for the in-progress state, pinned to a constant so the
    /// rendered `Text` and the VoiceOver announcement in `body` can't drift.
    static let signingInStatusText = "Signing you in\u{2026}"

    /// `ScrollViewReader` target for the sign-in error `Label`, so a failure
    /// scrolls into view for sighted users instead of only announcing to
    /// VoiceOver.
    private static let signInErrorScrollID = "signInError"

    /// Domain-then-code check (mirrors `urlErrorCode`'s type-then-string-
    /// fallback idiom) — a code-only check risks a false positive if some
    /// other `NSError` domain happens to reuse `ASAuthorizationError
    /// .canceled`'s raw code, which would silently swallow a real failure.
    static func isUserCancelledAppleSignIn(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASAuthorizationErrorDomain
            && nsError.code == ASAuthorizationError.canceled.rawValue
    }

    /// `.unknown` is where the no-Apple-Account case surfaces, and iOS has
    /// usually just shown its own Settings-pointing alert by the time this
    /// fires — so this copy agrees with the system (§6.6) instead of telling
    /// the user to "try again" on something retrying won't fix. The other
    /// codes (`.failed`, `.invalidResponse`, `.notHandled`) stay transient.
    static func appleSideFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationErrorDomain
            && nsError.code == ASAuthorizationError.unknown.rawValue {
            return "Sign in with Apple isn\u{2019}t available \u{2014} check that you\u{2019}re signed in to an Apple Account in Settings."
        }
        return "Sign in with Apple failed \u{2014} try again."
    }

    /// VoiceOver copy for `appRouter.invitePreviewState`'s resolved states
    /// — `.idle`/`.loading` return `nil` so the `.onChange` above stays
    /// silent while nothing's settled yet.
    static func invitePreviewAnnouncement(for state: AppRouter.InvitePreviewState) -> String? {
        switch state {
        case .idle, .loading:
            return nil
        case .loaded(let preview):
            let role = TripRole(rawValue: preview.role)
            let dateRange = InvitePreview.formattedDateRange(startDate: preview.startDate, endDate: preview.endDate)
            let roleText = role.map { ". Joining as \($0.rawValue.capitalized)." } ?? "."
            return "Invite loaded: \(preview.inviterName) invited you to \(preview.tripTitle), \(dateRange)\(roleText)"
        case .invalid:
            return "This invite link has expired or been revoked. Ask for a new link."
        case .unavailable:
            return "Couldn\u{2019}t load your invite details \u{2014} you can still sign in to join."
        }
    }

    /// Splits sign-in failures into three §6.6-compliant buckets — offline,
    /// server unreachable, and an on-our-end auth failure — so the copy
    /// states what happened rather than one generic message covering all
    /// three (and never tells you to check your connection when the
    /// problem was actually server-side).
    static func signInFailureMessage(for error: Error) -> String {
        switch urlErrorCode(error) {
        case .some(let code) where Self.offlineCodes.contains(code):
            return "You\u{2019}re offline \u{2014} connect to the internet and try again."
        case .some:
            return "Couldn\u{2019}t reach the server \u{2014} try again in a moment."
        case .none:
            return "Sign-in didn\u{2019}t go through on our end \u{2014} try again in a moment."
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff
    ]

    /// Mirrors `AppRouter.isInvalidInvite`'s type-then-string-fallback
    /// idiom: `URLError` is the common case, with the raw `NSURLErrorDomain`
    /// check as a fallback in case an underlying network failure surfaces
    /// wrapped in a different `Error` type (e.g. an `NSError` that was
    /// never bridged to `URLError`).
    static func urlErrorCode(_ error: Error) -> URLError.Code? {
        if let urlError = error as? URLError { return urlError.code }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return URLError.Code(rawValue: nsError.code)
    }
}
