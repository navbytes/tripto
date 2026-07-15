import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings + account deletion (M3 brief; Apple 5.1.1(v)). Reached via
/// `SettingsRoute` pushed onto the shared `NavigationStack` from
/// `HomeView`'s avatar tap.
struct SettingsView: View {
    @Query private var profiles: [Profile]
    /// P4.3 (docs/UX_REDESIGN_ROADMAP.md): backs the Export row's real
    /// "N trips · M items" subtitle — the same two domains
    /// `TripArchiveExporter.composeDocument(trips:items:profiles:)` already
    /// counts, read live off the local store via `@Query` rather than a
    /// one-off fetch, so the count on screen can never disagree with what
    /// tapping the row will actually export.
    @Query private var trips: [Trip]
    @Query private var items: [ItineraryItem]

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

    /// Tripto Archive v1 (docs/IMPORT_FORMAT.md) — "Import trips"/"Export
    /// trips" (roadmap 2.2/2.3). `archiveImportError` drives the
    /// atomic-failure alert; `archiveImportReport` drives either a plain
    /// success alert or the skip-detail sheet, split on the report's own
    /// `isFullSuccess`.
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
                        // Decorative live preview — the name field and the
                        // color picker's own selection state below already
                        // convey this.
                        .accessibilityHidden(true)
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
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

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
                            Text(Self.exportCountsText(tripCount: trips.count, itemCount: items.count))
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
        .alert("Import complete", isPresented: isPresentingArchiveImportSuccessAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(archiveImportReport.map(Self.importSummary) ?? "")
        }
        .sheet(isPresented: isPresentingArchiveImportReportSheet) {
            if let archiveImportReport {
                ArchiveImportReportSheet(report: archiveImportReport)
            }
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

    private var isPresentingArchiveImportSuccessAlert: Binding<Bool> {
        Binding(
            get: { archiveImportReport?.isFullSuccess == true },
            set: { isPresented in if !isPresented { archiveImportReport = nil } }
        )
    }

    private var isPresentingArchiveImportReportSheet: Binding<Bool> {
        Binding(
            get: { archiveImportReport != nil && archiveImportReport?.isFullSuccess == false },
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
                .contentShape(Rectangle())
                .frame(minHeight: 44)
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

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = info?["CFBundleVersion"] as? String ?? "\u{2014}"
        return "\(version) (\(build))"
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

    private static func importSummary(_ report: TripArchiveImportReport) -> String {
        let tripWord = report.tripsImported == 1 ? "trip" : "trips"
        let itemWord = report.itemsImported == 1 ? "item" : "items"
        return "\(report.tripsImported) \(tripWord), \(report.itemsImported) \(itemWord) imported."
    }

    /// P4.3 (docs/UX_REDESIGN_ROADMAP.md): the Export row's "N trips · M
    /// items" subtitle. Not `private` (unlike `importSummary` above) so
    /// `SettingsExportCountsTests` can pin the pluralization directly.
    static func exportCountsText(tripCount: Int, itemCount: Int) -> String {
        let tripWord = tripCount == 1 ? "trip" : "trips"
        let itemWord = itemCount == 1 ? "item" : "items"
        return "\(tripCount) \(tripWord) \u{00B7} \(itemCount) \(itemWord)"
    }
}

/// Settings' "Import trips" result when the archive had any skips or flags
/// — a clean import gets the simpler `.alert` instead (`SettingsView.body`'s
/// split on `TripArchiveImportReport.isFullSuccess`).
private struct ArchiveImportReportSheet: View {
    let report: TripArchiveImportReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Trips imported", value: "\(report.tripsImported)")
                    LabeledContent("Items imported", value: "\(report.itemsImported)")
                    if report.profilesImported > 0 {
                        LabeledContent("Travellers added", value: "\(report.profilesImported)")
                    }
                }

                if report.zoneAssumedCount > 0 {
                    Section {
                        Text(zoneAssumedText)
                    }
                }

                if !report.tripSkips.isEmpty {
                    Section("Trips skipped") {
                        ForEach(Array(report.tripSkips.enumerated()), id: \.offset) { _, skip in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(skip.title.isEmpty ? "Untitled trip" : skip.title)
                                    .font(Typo.body(weight: .semibold))
                                Text(Self.sentenceCased(skip.reason.reportText))
                                    .font(Typo.body(Typo.Size.caption))
                                    .foregroundStyle(Palette.slate)
                            }
                            // UX#7: read as one VoiceOver element (name +
                            // reason together), not two separate stops.
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if !report.itemSkips.isEmpty {
                    Section("Items skipped") {
                        ForEach(Array(report.itemSkips.enumerated()), id: \.offset) { _, skip in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                // UX#3: the item's own title/category, not
                                // the raw archive item id (often empty).
                                Text(skip.itemLabel)
                                    .font(Typo.body(weight: .semibold))
                                Text("\(Self.sentenceCased(skip.reason.reportText)) \u{2014} "
                                    + (skip.tripTitle.isEmpty ? "Untitled trip" : skip.tripTitle))
                                    .font(Typo.body(Typo.Size.caption))
                                    .foregroundStyle(Palette.slate)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if report.droppedNotesCount > 0 {
                    Section {
                        Text(droppedNotesText)
                    }
                }
            }
            .navigationTitle("Import results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // UX#7: this sheet's own content is the only signal a VoiceOver
            // user gets that the import finished — announce the headline
            // counts the moment it presents, same as any other result toast.
            .onAppear {
                AccessibilityNotification.Announcement(summaryAnnouncement).post()
            }
        }
    }

    private var summaryAnnouncement: String {
        let tripWord = report.tripsImported == 1 ? "trip" : "trips"
        let itemWord = report.itemsImported == 1 ? "item" : "items"
        let skipCount = report.tripSkips.count + report.itemSkips.count
        let skipWord = skipCount == 1 ? "item" : "items"
        return "\(report.tripsImported) \(tripWord), \(report.itemsImported) \(itemWord) imported. "
            + "\(skipCount) \(skipWord) skipped."
    }

    private var zoneAssumedText: String {
        let word = report.zoneAssumedCount == 1 ? "item" : "items"
        return "\(report.zoneAssumedCount) \(word) assumed your device time zone \u{2014} check times."
    }

    private var droppedNotesText: String {
        let word = report.droppedNotesCount == 1 ? "trip\u{2019}s notes weren\u{2019}t" : "trips\u{2019} notes weren\u{2019}t"
        return "\(report.droppedNotesCount) \(word) imported \u{2014} Tripto doesn\u{2019}t store trip-level notes yet."
    }

    /// UX#6: BUILD_PLAN §6.2 sentence case — `reportText` values are
    /// already lowercase; only the first letter needs raising (`.capitalized`
    /// title-cased every word, e.g. "Missing Id").
    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
