import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings + account deletion (M3 brief; Apple 5.1.1(v)). Reached via
/// `SettingsRoute` pushed onto the shared `NavigationStack` from
/// `HomeView`'s avatar tap.
struct SettingsView: View {
    @Query private var profiles: [Profile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus
    /// P6.1: "Open trip" on an already-imported skip row routes through the
    /// same app-wide "go to this trip from wherever you are" mechanism a
    /// widget/Spotlight/Siri tap already uses (`AppRouter.openTrip(id:)`) —
    /// `HomeView`'s own `.onChange(of: appRouter.tripToOpen)` does the
    /// actual pull+push, unchanged.
    @Environment(AppRouter.self) private var appRouter
    @Environment(\.dismiss) private var dismiss
    /// V1 aligned-rows relayout: stacks the avatar+name row vertically at
    /// accessibility Dynamic Type sizes — same `isAccessibilitySize`
    /// convention `TripCard`'s `metaLayout`/`topLayout` already establish.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// UX P6.5: the toggle side of `HomeView`'s "been" reveal row — device-
    /// local (see the section's own doc comment below), read/written
    /// through the shared key so the two views can't drift apart.
    @AppStorage(HomePastTripsVisibility.appStorageKey) private var showPastTrips = true
    /// T2 (ROADMAP 3.3): device-local, same reasoning as `showPastTrips`
    /// above — every device registers (or doesn't) its own push token.
    /// Bound through `suggestionAlertsToggleBinding` below rather than
    /// directly, since flipping it has a real request/register/upload (or
    /// delete) side effect, unlike `showPastTrips`' plain persisted bool.
    @AppStorage(SuggestionAlertsPreference.appStorageKey) private var suggestionAlertsEnabled = false

    @State private var displayName = ""
    /// UX audit finding 9: the signed-in user's own avatar color, editable
    /// here with the same four-swatch picker `TripProfileFormSheet` already
    /// offers for non-app profiles — previously fixed/seeded with no way to
    /// change it, the one asymmetry between "my own avatar" and "a kid's/
    /// grandparent's avatar" as the same conceptual object.
    @State private var avatarColor = ""
    /// P8a (avatar photos): mirrors `avatarColor`'s own draft-until-Save
    /// shape — the picker's own upload runs immediately (there's no
    /// realistic way to defer the actual bytes upload until "Save"), but
    /// the `Profile.avatarPath` row write + sync enqueue wait for the same
    /// explicit "Save changes" tap `displayName`/`avatarColor` already do.
    @State private var avatarPath: String?
    /// `displayName`/`avatarColor` use "still empty" as their own "not yet
    /// seeded from `myProfile`" signal, but `nil` is `avatarPath`'s legitimate
    /// "no photo" value too — this flag is the unambiguous version of that
    /// same signal, so seeding runs exactly once (see `.onAppear`/`.onChange`
    /// below) and a deliberate "Remove photo" is never mistaken for "not
    /// seeded yet" and clobbered by a later reactive re-fill.
    @State private var hasSeededAvatarPath = false
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

    /// Tripto Archive v1 (docs/IMPORT_FORMAT.md) — "Import trips"/"Export
    /// trips" (roadmap 2.2/2.3). `archiveImportError` drives the
    /// atomic-failure alert (nothing was imported at all — no report to
    /// show); `archiveImportReport` drives `ImportResultSheet` (P6.1,
    /// docs/UX_REDESIGN_ROADMAP.md) — one branded sheet for every
    /// successful import, whether or not it had skips.
    @State private var isPresentingArchiveImporter = false
    @State private var isImportingArchive = false
    @State private var isExportingArchive = false
    @State private var archiveImportError: TripArchiveError?
    @State private var archiveImportReport: TripArchiveImportReport?
    @State private var didFinishArchiveImport = false
    /// D2/SEC: the export temp file's own URL is the source of truth (not
    /// `[Any]?` directly) so it can be deleted the moment the share sheet
    /// dismisses — see `exportShareItems` below.
    @State private var exportTempFileURL: URL?

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

    /// P8a: same "widen isProfileChanged" reasoning as `isColorChanged`'s own
    /// doc comment, for the photo row now above it.
    private var isPhotoChanged: Bool {
        hasSeededAvatarPath && avatarPath != myProfile?.avatarPath
    }

    private var isProfileChanged: Bool { isNameChanged || isColorChanged || isPhotoChanged }

    /// P4.3 (docs/UX_REDESIGN_ROADMAP.md): backs the Export row's real "N
    /// trips · M items" subtitle. Fix-round N1: `modelContext.fetchCount`
    /// instead of two unfiltered `@Query`s — those loaded (and kept
    /// `@Query`-observing) every `Trip`/`ItineraryItem` row in the store just
    /// to read a `.count`; `fetchCount` asks SwiftData for the row count
    /// directly, same two domains `TripArchiveExporter.composeDocument`
    /// counts, without materializing the objects. `exportArchive()` still
    /// does its own real fetch at export time (it needs the actual rows,
    /// not just a count) — untouched.
    private var exportTripCount: Int {
        (try? modelContext.fetchCount(FetchDescriptor<Trip>())) ?? 0
    }

    private var exportItemCount: Int {
        (try? modelContext.fetchCount(FetchDescriptor<ItineraryItem>())) ?? 0
    }

    var body: some View {
        Form {
            Section("Profile") {
                // V1 aligned-rows relayout (client-approved): the 56pt
                // avatar (with "Change photo"/"Remove" grouped directly
                // under it, no separator — `AvatarPhotoPicker`'s own
                // `actionsBelowAvatar: true`) beside a labeled "Display
                // name" field — see `profileAvatarRow`'s own doc comment.
                profileAvatarRow
                    .disabled(isDeletingAccount)
                    .opacity(isDeletingAccount ? 0.5 : 1)

                // UX audit finding 9: same `AvatarColorPicker`
                // `TripProfileFormSheet` uses for a non-app profile — the
                // signed-in user's own avatar was the one avatar in the app
                // with no way to recolor it.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Avatar color")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.slate)
                    AvatarColorPicker(selection: $avatarColor)
                    // V1 relayout: this row's whole reason to exist is
                    // otherwise invisible until the one time a photo comes
                    // off — names it right under the swatches instead.
                    Text("Shows on your initials when there\u{2019}s no photo")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
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
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            // UX P6.5 (`.claude/company/ux-redesign/DECISIONS.md`
            // 2026-07-15): device-local, deliberately not synced — every
            // device gets its own choice, same reasoning a Mail/Photos
            // "hide" preference would use. `HomeView` reads the same
            // `HomePastTripsVisibility.appStorageKey` for the reveal row.
            Section {
                Toggle("Show past trips", isOn: $showPastTrips)
            } footer: {
                Text("Past trips stay on Home when this is on.")
                    .font(Typo.body(Typo.Size.caption))
            }

            // T2 (ROADMAP 3.3, EI-5): pulled into its own explicitly-typed
            // `some View` property rather than inlined here — this `body`
            // is already at the type checker's "reasonable time" limit (see
            // `isPresentingArchiveImportError`'s own doc comment below).
            notificationsSection

            // P4.3 (docs/UX_REDESIGN_ROADMAP.md): "Your data" moves above
            // Account — bring-your-history-in via any LLM is this product's
            // most distinctive feature, not a third link under a paragraph.
            Section {
                // Featured, not a plain row — `.listRowInsets`/
                // `.listRowBackground(.clear)` let this one row opt out of
                // the Form's default row chrome and render its own amber-
                // wash card, same technique any custom-styled Form row uses;
                // every other row on this screen keeps stock Form styling.
                conversionPromptFeatureCard
                    .padding(.vertical, Spacing.xs)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                Button {
                    isPresentingArchiveImporter = true
                } label: {
                    if isImportingArchive {
                        HStack {
                            ProgressView()
                            Text("Importing\u{2026}")
                        }
                    } else {
                        Text("Import trips")
                    }
                }
                .disabled(isImportingArchive || isExportingArchive || isDeletingAccount)

                Button {
                    exportArchive()
                } label: {
                    if isExportingArchive {
                        HStack {
                            ProgressView()
                            Text("Preparing export\u{2026}")
                        }
                    } else {
                        // P4.3: real counts instead of a bare label — "N
                        // trips · M items" is the difference between
                        // trusting a backup and hoping.
                        HStack {
                            Text("Export trips")
                            Spacer()
                            Text(Self.exportCountsText(tripCount: exportTripCount, itemCount: exportItemCount))
                                .font(Typo.body(Typo.Size.caption))
                                .foregroundStyle(Palette.slate)
                        }
                    }
                }
                .disabled(isImportingArchive || isExportingArchive || isDeletingAccount)
            } header: {
                Text("Your data")
            } footer: {
                Text("Import trips from a Tripto Archive file, or export your trips to share or back up.")
                    .font(Typo.body(Typo.Size.caption))
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
                // Pushes `PrivacySummaryView` (plain-language "at a glance"
                // summary + a link to the full published policy) — replaces
                // the old direct-to-browser "Privacy policy" link so there's
                // one primary privacy entry, not two differently-shaped ones.
                NavigationLink("Privacy") {
                    PrivacySummaryView()
                }
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
                            .accessibilityHidden(true)
                        Text("Back")
                    }
                }
                // UX#5: leaving mid-import used to silently drop the
                // report (including any "check times" zone-assumption
                // warnings) even though the data had already imported.
                .disabled(isDeletingAccount || isImportingArchive || isExportingArchive)
            }
        }
        .toastOverlay($toast)
        // N2 (P6 fix round): opens `ImportResultSheet` directly with a
        // representative report — same shape as `HomeView`'s own
        // `-uitestOpenSettings`/`-uitestOpenShare` hooks, letting a
        // screenshot pass reach this sheet without a real archive-file
        // import flow.
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitestOpenImportResult") {
                archiveImportReport = Self.uitestSampleImportReport
            }
            #endif
        }
        .onAppear {
            if displayName.isEmpty {
                displayName = myProfile?.displayName ?? ""
            }
            if avatarColor.isEmpty {
                avatarColor = myProfile?.avatarColor ?? ""
            }
            seedAvatarPathIfNeeded()
        }
        // Covers a brand-new sign-in: `myProfile` can still be nil at
        // `.onAppear` (the first `pullHome()` hasn't landed yet) — this
        // fills the field reactively the moment it arrives, but only while
        // the field is still untouched, so it never clobbers something the
        // user already started typing. `displayName` is always non-empty
        // for a real profile (the backend's `handle_new_user` trigger seeds
        // it), so this is also the reliable "myProfile just arrived" signal
        // `seedAvatarPathIfNeeded()` piggybacks on below — `avatarPath`
        // itself has no such non-nil guarantee to key off (no photo is a
        // legitimate value), so it can't watch its own DTO field the same way.
        .onChange(of: myProfile?.displayName) { _, newValue in
            if displayName.isEmpty, let newValue {
                displayName = newValue
            }
            seedAvatarPathIfNeeded()
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
        .onChange(of: avatarPath) { _, _ in
            if nameSaveError != nil {
                nameSaveError = nil
            }
        }
        // Same VoiceOver gap `TripFormView`'s `saveError` announcement
        // closes — a write failure otherwise has no spoken feedback.
        .onChange(of: nameSaveError) { _, newValue in
            if let newValue {
                AccessibilityNotification.Announcement(newValue).post()
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
        .fileImporter(isPresented: $isPresentingArchiveImporter, allowedContentTypes: [.json]) { result in
            handleArchivePick(result)
        }
        .activityShareSheet(items: exportShareItems)
        .sensoryFeedback(.success, trigger: didFinishArchiveImport)
        .alert("Couldn\u{2019}t import", isPresented: isPresentingArchiveImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(archiveImportError?.message ?? "")
        }
        .sheet(isPresented: isPresentingArchiveImportReportSheet) {
            if let archiveImportReport {
                ImportResultSheet(
                    report: archiveImportReport,
                    onOpenTrip: { tripId in appRouter.openTrip(id: tripId) },
                    // Pops SettingsView itself back to Home — the sheet's
                    // own `\.dismiss` only ever closes the sheet, so this
                    // screen has to supply its own dismissal for "go see
                    // your trips" to actually leave Settings.
                    onSeeTrips: { dismiss() }
                )
            }
        }
    }

    /// T2 (ROADMAP 3.3, EI-5): requests notification permission + registers
    /// for APNs on ON, deletes the `device_tokens` row on OFF (leaving the
    /// system permission itself alone — an app can't revoke that).
    /// `suggestionAlertsToggleBinding` owns the whole request/register/
    /// upload-or-delete flow; this is just the row.
    private var notificationsSection: some View {
        Section {
            Toggle("Suggestion alerts", isOn: suggestionAlertsToggleBinding)
                .disabled(isDeletingAccount)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get notified when someone suggests an item to add to a trip.")
                .font(Typo.body(Typo.Size.caption))
        }
    }

    /// V1 aligned-rows relayout (client-approved): Row 1 of the Profile
    /// section — the avatar (`AvatarPhotoPicker` with `actionsBelowAvatar:
    /// true`, so "Change photo"/"Remove" render grouped directly under it,
    /// not beside it) next to a labeled "Display name" field. The field's
    /// own binding/validation/save flow is untouched — only its position
    /// (now labeled, beside the avatar rather than its own bare row below)
    /// changed.
    ///
    /// Stacks vertically at accessibility Dynamic Type sizes — same
    /// `isAccessibilitySize` -> `AnyLayout` swap `TripCard`'s own
    /// `metaLayout`/`topLayout` already establish: side by side, a 56pt
    /// circle plus a full-width text field has no room for both to stay
    /// legible once type scales up.
    private var profileAvatarRow: some View {
        // Fix round 2: the name block rides `AvatarPhotoPicker`'s
        // `besideAvatar` slot instead of an outer HStack — composed outside,
        // the picker's column (avatar over the "Change photo"/"Remove" row)
        // was as wide as that actions row, so the field started mid-card and
        // read as centered. Inside the slot, the field hugs the 56pt circle
        // and the actions row spans full width below, matching the approved
        // V1 mockup. AX-size stacking lives in the component now.
        AvatarPhotoPicker(
            initial: initials(from: displayName),
            colorName: avatarColor.isEmpty ? "slate" : avatarColor,
            avatarPath: $avatarPath,
            uploaderUserId: authManager.userId,
            toast: $toast,
            diameter: 56,
            removeLabel: "Remove",
            actionsBelowAvatar: true
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Display name")
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                TextField("Display name", text: $displayName)
                    .font(Typo.body(weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Broken out of `body` as explicit-typed `Binding<Bool>` properties
    /// (rather than inline `Binding(get:set:)` closures in the modifier
    /// chain) — an already-long `body` plus several inline closures pushed
    /// the type checker over its "reasonable time" limit.
    private var isPresentingArchiveImportError: Binding<Bool> {
        Binding(
            get: { archiveImportError != nil },
            set: { isPresented in if !isPresented { archiveImportError = nil } }
        )
    }

    /// P6.1: always shows once there's a report — the old alert-vs-sheet
    /// split on `isFullSuccess` is gone; `ImportResultSheet` itself degrades
    /// to the small/clean-import case rather than needing a second, simpler
    /// presentation to fall back to.
    private var isPresentingArchiveImportReportSheet: Binding<Bool> {
        Binding(
            get: { archiveImportReport != nil },
            set: { isPresented in if !isPresented { archiveImportReport = nil } }
        )
    }

    /// SEC LOW: bridges `exportTempFileURL` (the real source of truth) to
    /// `.activityShareSheet`'s `[Any]?` — when the sheet dismisses (setting
    /// this back to `nil`), the temp file is deleted immediately rather
    /// than left in `tmp/` indefinitely.
    private var exportShareItems: Binding<[Any]?> {
        Binding(
            get: { exportTempFileURL.map { [$0] } },
            set: { newValue in
                guard newValue == nil, let url = exportTempFileURL else { return }
                try? FileManager.default.removeItem(at: url)
                exportTempFileURL = nil
            }
        )
    }

    /// T2: same "explicit `Binding(get:set:)`" shape as `isPresentingArchiveImportError`/
    /// `exportShareItems` above — intercepts every flip to run the real
    /// request/register/upload-or-delete flow (`setSuggestionAlerts`)
    /// instead of just persisting a bool.
    private var suggestionAlertsToggleBinding: Binding<Bool> {
        Binding(
            get: { suggestionAlertsEnabled },
            set: { newValue in Task { await setSuggestionAlerts(newValue) } }
        )
    }

    /// ponytail: no busy-guard against a rapid double-tap while this is in
    /// flight (unlike `isImportingArchive`/`isExportingArchive`'s explicit
    /// state) — a second tap just starts a second, independently-correct
    /// pass (iOS itself de-dupes a concurrent `requestAuthorization`), and
    /// the toggle's own row already reflects whichever pass lands last. Add
    /// a busy flag if that's ever observed as a real rough edge.
    private func setSuggestionAlerts(_ enabled: Bool) async {
        guard enabled else {
            suggestionAlertsEnabled = false
            await SuggestionAlertsToggle.disable(userId: authManager.userId)
            return
        }
        suggestionAlertsEnabled = true
        let outcome = await SuggestionAlertsToggle.enable(userId: authManager.userId)
        if SuggestionAlertsToggle.shouldRevertToOff(for: outcome) {
            suggestionAlertsEnabled = false
        }
        if let message = SuggestionAlertsToggle.failureMessage(for: outcome) {
            toast = message
        }
    }

    private func backTapped() {
        if isProfileChanged {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    /// P4.3 (docs/UX_REDESIGN_ROADMAP.md): "Coming from another app?" —
    /// bring-your-history-in-via-any-LLM used to be a plain "Copy
    /// conversion prompt" button, the third link under a four-line
    /// paragraph. Same `copyConversionPrompt()` action underneath, unchanged
    /// — only the visual weight/copy changed to match how distinctive the
    /// feature actually is.
    ///
    /// AA: title `Palette.ink` on `Palette.amberSoft` measures ~14.4:1
    /// light / ~10.9:1 dark (the exact pairing `AddItemSheet.footerBar`'s
    /// "Save & add the return leg" button already measured and documented —
    /// reused rather than re-derived). The body line is `Palette.ink` at
    /// 75% opacity for a visibly secondary tone without dropping below AA:
    /// `Palette.slate` in this same spot measures only ~4.2:1 light, under
    /// the 4.5:1 bar for this caption-regular text (`amberInk`, the OTHER
    /// obvious "secondary ink" candidate, measures ~4.45:1 there too — both
    /// too close to the line); `ink` at 75% measures ~6.8:1 light / ~6.9:1
    /// dark. The tile/CTA reuse `Palette.amber`/`onAmber`, the app's
    /// existing ~7:1 CTA-pill pairing.
    private var conversionPromptFeatureCard: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Palette.amber)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "sparkles").foregroundStyle(Palette.onAmber)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Coming from another app?")
                    .font(Typo.body(weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text("Copy a prompt, paste it into any AI assistant with your old trip data, and import whatever it gives back.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy the prompt") {
                    copyConversionPrompt()
                }
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Palette.onAmber)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Palette.amber, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(isImportingArchive || isExportingArchive || isDeletingAccount)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
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

    /// P8a: seeds `avatarPath` from `myProfile` exactly once — see
    /// `hasSeededAvatarPath`'s own doc comment for why this can't reuse the
    /// "still empty" trick `displayName`/`avatarColor` use.
    private func seedAvatarPathIfNeeded() {
        guard !hasSeededAvatarPath, let myProfile else { return }
        avatarPath = myProfile.avatarPath
        hasSeededAvatarPath = true
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = info?["CFBundleVersion"] as? String ?? "\u{2014}"
        return "\(version) (\(build))"
    }

    /// UX audit finding 9: widened from the original `saveDisplayName()` to
    /// also persist a changed `avatarColor` — one save affordance for both
    /// fields in the Profile section, same as `TripProfileFormSheet`'s
    /// single "Save changes" covering its name+color pair. P8a: widened
    /// again for `avatarPath` — the actual upload already happened (via
    /// `AvatarPhotoPicker`, atomically, before `avatarPath` ever changed),
    /// so this only ever writes a path that's already live in the bucket.
    private func saveProfile() {
        guard let profile = myProfile else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !trimmed.isEmpty && trimmed != profile.displayName
        let colorChanged = !avatarColor.isEmpty && avatarColor != profile.avatarColor
        let photoChanged = hasSeededAvatarPath && avatarPath != profile.avatarPath
        guard nameChanged || colorChanged || photoChanged else { return }
        nameSaveError = nil
        if nameChanged { profile.displayName = trimmed }
        if colorChanged { profile.avatarColor = avatarColor }
        if photoChanged { profile.avatarPath = avatarPath }
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
        let changedCount = [nameChanged, colorChanged, photoChanged].filter { $0 }.count
        if changedCount > 1 {
            toast = "Profile updated"
        } else if nameChanged {
            toast = "Name updated"
        } else if colorChanged {
            toast = "Avatar color updated"
        } else {
            toast = "Photo updated"
        }
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

    // MARK: - Tripto Archive (import/export, roadmap 2.2/2.3)

    private func handleArchivePick(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            // UX#8: a picker-level failure is "couldn't open the file"
            // (permissions/IO), not "this isn't a valid archive" — distinct
            // copy from a JSON parse failure.
            archiveImportError = .unreadableFile
        case .success(let url):
            importArchive(from: url)
        }
    }

    private func importArchive(from url: URL) {
        guard !isImportingArchive else { return }
        guard let userId = authManager.userId else {
            toast = "Sign in first, then try importing again."
            return
        }
        isImportingArchive = true
        Task {
            defer { isImportingArchive = false }
            // `.fileImporter` hands back a security-scoped URL — must
            // bracket the read (Apple's documented contract for picked
            // files outside the app's own sandbox).
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            // SEC LOW: reject an oversized file via its size attribute
            // BEFORE reading the whole thing into memory.
            if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                fileSize > TripArchiveBounds.maxFileBytes {
                archiveImportError = .fileTooLarge
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                archiveImportError = .unreadableFile
                return
            }
            let outcome = await TripArchiveImporter.importArchive(
                data: data, modelContext: modelContext, syncEngine: syncEngine, userId: userId
            )
            switch outcome {
            case .success(let report):
                archiveImportReport = report
                if report.tripsImported > 0 || report.itemsImported > 0 {
                    didFinishArchiveImport.toggle()
                }
            case .failure(let error):
                archiveImportError = error
            }
        }
    }

    /// D2/M3+UX#4: async now (`TripArchiveExporter.export` runs compose+
    /// encode off the main actor for a large local store) with the same
    /// busy/disabled + double-tap guard `importArchive` already has.
    private func exportArchive() {
        guard !isExportingArchive else { return }
        isExportingArchive = true
        Task {
            defer { isExportingArchive = false }
            let trips: [Trip]
            let items: [ItineraryItem]
            let profiles: [TripProfile]
            do {
                // L7 fix: a fetch failure used to silently degrade to an
                // empty array, producing a misleadingly "successful" but
                // empty export instead of a clear failure.
                trips = try modelContext.fetch(FetchDescriptor<Trip>())
                items = try modelContext.fetch(FetchDescriptor<ItineraryItem>())
                profiles = try modelContext.fetch(FetchDescriptor<TripProfile>())
            } catch {
                toast = "Couldn\u{2019}t export your trips. Try again."
                return
            }
            do {
                exportTempFileURL = try await TripArchiveExporter.export(trips: trips, items: items, profiles: profiles)
            } catch {
                toast = "Couldn\u{2019}t export your trips. Try again."
            }
        }
    }

    /// UX#2: the IMPORT_FORMAT.md appendix prompt, bundled verbatim so a
    /// user migrating from another app has an in-app path to it — no web
    /// link, just copy + paste into any AI assistant alongside their data.
    private func copyConversionPrompt() {
        toast = ClipboardFeedback.copy(Self.conversionPromptText, label: "Prompt")
    }

    private static let conversionPromptText = """
    Convert my trip data below into Tripto Archive v1 JSON. Rules:
    - Envelope: {"format":"tripto-archive","version":1,"trips":[\u{2026}]}.
    - Follow the trip/item fields exactly as specified in sections 2-3 of Tripto's IMPORT_FORMAT.md \
    (categories: flight, hotel, activity, food, transport; snake_case keys).
    - Give every trip and item a stable id (reuse the source's ids/PNRs where possible \u{2014} re-imports dedupe by id).
    - Dates YYYY-MM-DD; times as naive local YYYY-MM-DDTHH:MM plus the IANA tz you know for that place/airport \
    (and arrival_tz for flights). Use from_iata/to_iata airport codes.
    - country_code is ISO 3166-1 alpha-2. travellers lists companions by display name \u{2014} do NOT include me (the account owner).
    - Bookings that aren't flights become items too: hotels \u{2192} hotel, car rentals/transfers \u{2192} transport, \
    attraction tickets \u{2192} activity. Put PNRs in confirmation, disruption/refund history in notes.
    - Skip nothing; if a trip has no known dates, still emit it (Tripto will report it as skipped rather than guess).

    My data: \u{2026}
    """

    /// P4.3 (docs/UX_REDESIGN_ROADMAP.md): the Export row's "N trips · M
    /// items" subtitle. Not `private` so `SettingsExportCountsTests` can
    /// pin the pluralization directly (same reasoning as `ImportResultSheet
    /// .subtitleText`/`primaryActionText`'s own non-private statics).
    static func exportCountsText(tripCount: Int, itemCount: Int) -> String {
        let tripWord = tripCount == 1 ? "trip" : "trips"
        let itemWord = itemCount == 1 ? "item" : "items"
        return "\(tripCount) \(tripWord) \u{00B7} \(itemCount) \(itemWord)"
    }

    #if DEBUG
    /// N2 (P6 fix round): `-uitestOpenImportResult`'s fixture — a
    /// feature-complete report (stat tiles incl. travellers, a recoverable
    /// skip, a non-recoverable one, the zone-assumed note) so the capture
    /// UI test shows the sheet at its most representative, not the
    /// degraded/empty case (`ImportResultSheetTests` already covers that
    /// case's own text mapping directly).
    private static let uitestSampleImportReport = TripArchiveImportReport(
        tripsImported: 20, itemsImported: 67, profilesImported: 12,
        tripSkips: [
            .init(tripId: "1", title: "Parents\u{2019} visit to Hong Kong", reason: .cancelled),
            .init(tripId: "2", title: "Bangkok", reason: .alreadyImported, existingLocalTripId: UUID()),
            .init(tripId: "3", title: "", reason: .noStartDate)
        ],
        itemSkips: [
            .init(tripId: "1", tripTitle: "IndiGo booking", itemId: "i1", itemLabel: "Flight 6E204", reason: .noStartTime)
        ],
        zoneAssumedCount: 3,
        droppedNotesCount: 20
    )
    #endif
}
