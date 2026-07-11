import Supabase
import SwiftData
import SwiftUI

/// TI-0→TI-3 (`docs/BUILD_PLAN.md`): the app-side half of paste-to-import —
/// a large free-text box the user pastes anything trip-related into
/// (a booking confirmation, a day plan, a packing list, or any mix),
/// submitted to `ingest-text` via `Supa.invoke`.
///
/// On-device-first (Apple FoundationModels, iOS 26+): `currentRoute`
/// decides, live as the user types, whether Import will run the extraction
/// entirely on-device (`OnDeviceExtractor`, pasted text never leaves the
/// phone) or fall back to the remote path above. Routing/consent-dialog
/// rules are pure functions (`ImportRouting`, `Features/Trip/
/// ImportExtraction.swift`) — see `submitOnDevice()`'s doc comment for the
/// full on-device flow, including its own fallback-to-remote path.
///

/// TI-3: one sheet, one request, no caller-supplied mode. Earlier (TI-0/
/// TI-2) this took a `Kind` (`.booking` vs `.packing`) the caller had to
/// pick *before* the user typed anything — an invisible mode a user
/// pasting a day plan under "booking" would silently fail against (no
/// activities extracted) with no way to know a "packing" mode even
/// existed elsewhere in the app. `ingest-text` now always runs both
/// extractions server-side and returns both results in one response —
/// this sheet just renders whichever of the two actually found
/// something, in one screen:
///   - Itinerary items (bookings + scheduled activities): the function
///     already inserted `status: "suggested"` rows server-side (same
///     review pipeline as email import — `ImportReviewBanner`/
///     `SuggestedItemsSheet` pick them up on their own), so this sheet
///     never touches SwiftData for those — it only reports the created
///     count back via `onItineraryItemsImported` so the caller (which
///     already owns a `toast` state) can show it.
///   - Packing items: `ingest-text` does *not* write these to the DB (the
///     app already has an offline-first insert path) — it only extracts
///     and normalizes them. This sheet renders them as a pre-checked
///     vetting checklist so the user can drop anything mis-extracted
///     before confirming, then hands the still-checked rows to
///     `onPackingConfirmed` so the caller inserts each one through
///     `PackingItem.insert(...)` — same "sheet is a dumb form, caller
///     owns the writes" split `PackingItemFormSheet` already uses.
/// Every call site (Itinerary, Bookings, Packing tabs) wires up both
/// callbacks identically now — which of the two actually fires depends on
/// what was in the pasted text, not on which tab the user happened to be
/// on when they opened this sheet.
struct PasteImportSheet: View {
    let tripId: UUID
    /// Called once with the created count as soon as the response comes
    /// back, if non-zero — independent of whether packing items also came
    /// back (the sheet may still be showing the packing checklist).
    var onItineraryItemsImported: ((Int) -> Void)? = nil
    /// Called with the still-checked, possibly-edited rows once the user
    /// confirms the vetting checklist. This sheet never inserts anything
    /// itself — see the type's doc comment.
    var onPackingConfirmed: (([(label: String, groupKey: PackingGroupKey)]) -> Void)? = nil
    /// The signed-out local trip creator's own uid (mirrors
    /// `AddItemSheet.tripCreatedBy`'s doc comment exactly) — the on-device
    /// path inserts suggested rows itself, through the same SwiftData +
    /// outbox path `AddItemSheet.save()` uses, so it needs the identical
    /// fallback creator id when `authManager.userId` is `nil`. `nil` is
    /// only reachable in practice if a future call site forgets to pass
    /// this; `submitOnDevice()` falls back to remote rather than inserting
    /// with no creator at all in that case.
    var tripCreatedBy: UUID? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @State private var rawText = ""
    @State private var isSubmitting = false
    /// Guideline 5.1.2(i) (rewritten 2025-11-13): true while the AI-import
    /// consent dialog is up — shown instead of calling `submit()` directly
    /// the first time (see `AIImportConsent`), never again once consent is
    /// on record.
    @State private var isPresentingAIConsent = false
    @State private var errorMessage: String?
    /// Non-nil once a 200 response came back with nothing found at all
    /// (`created: 0` and no packing items) — not an error (this
    /// milestone's brief: "a 200 response with nothing found ... is NOT an
    /// error"), just an invitation to edit and retry.
    @State private var noResultsMessage: String?
    /// Non-empty once extraction found packing items — swaps the sheet's
    /// body from the paste box to the vetting checklist. Itinerary items
    /// (if any) were already inserted server-side by this point regardless.
    @State private var packingCandidates: [PackingCandidate] = []
    /// Set alongside `packingCandidates` so the checklist screen can show
    /// "N items also added to your itinerary" above the packing list when
    /// a single paste produced both.
    @State private var itineraryItemsCreated = 0
    /// Review fix: `ingest-text` runs both extractions independently
    /// (`Promise.allSettled` server-side) — one side transiently failing
    /// while the other succeeds used to be indistinguishable from "ran
    /// fine, found nothing," which silently dropped whatever the failed
    /// side would have found with zero user-visible signal. Non-nil text
    /// here means "we couldn't check for X, not that there wasn't any."
    @State private var partialFailureNote: String?

    /// Checkbox container + its checkmark glyph, and the group-tag icon —
    /// see the shared `@ScaledMetric` recipe used throughout Features/Trip.
    @ScaledMetric(relativeTo: .body) private var checkboxSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var checkmarkSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var groupIconSize: CGFloat = 10

    private struct PackingCandidate: Identifiable {
        let id = UUID()
        var label: String
        let groupKey: PackingGroupKey
        var isChecked = true
    }

    private var isReviewingPacking: Bool { !packingCandidates.isEmpty }
    private var trimmedText: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedText.isEmpty && !isSubmitting }

    /// The runtime capability check (R4 §6's verified `canImport` +
    /// `#available` combo): `OnDeviceExtractor` only exists inside that
    /// guard, so nothing outside it may reference the type unguarded —
    /// every other on-device-aware property/method below reads this
    /// instead of repeating the guard inline.
    private var isOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return OnDeviceExtractor.isAvailable
        }
        #endif
        return false
    }

    /// Live route for the CURRENTLY typed/pasted text (recomputed on every
    /// keystroke) — drives both the footer copy below and the Import
    /// button's tap action, so what the user reads before tapping always
    /// matches what tapping will actually do.
    private var currentRoute: ImportRoute {
        ImportRouting.route(
            isOnDeviceAvailable: isOnDeviceAvailable,
            textFitsOnDevice: ImportContextBudget.textFits(trimmedText)
        )
    }
    /// Nit: the checked rows that will actually become packing items — a
    /// candidate edited down to an empty/whitespace-only label is dropped
    /// here rather than handed to `onPackingConfirmed`, where
    /// `PackingItem.insert`'s own empty-label guard would silently no-op
    /// it while the confirm button's count still claimed it'd be added.
    private var toAddCandidates: [(label: String, groupKey: PackingGroupKey)] {
        packingCandidates
            .filter(\.isChecked)
            .compactMap { candidate in
                let trimmed = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (label: trimmed, groupKey: candidate.groupKey)
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(title: title, onCancel: { dismiss() })
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        if isReviewingPacking {
                            packingReviewSection
                        } else {
                            pasteSection
                        }
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        // R4 §4: give the system "at least ~1 second of lead time" before
        // the user can plausibly tap Import. A hint only (see
        // `OnDeviceExtractor.prewarm()`'s doc comment) — never blocks this
        // appearance, and a no-op whenever on-device isn't available.
        .onAppear {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                OnDeviceExtractor.prewarm()
            }
            #endif
        }
        // Guideline 5.1.2(i) (rewritten 2025-11-13): explicit, affirmative
        // permission before sharing pasted text with the third-party AI —
        // the passive disclosure line in `pasteSection` is no longer
        // sufficient on its own. Native `confirmationDialog` (same idiom as
        // `AddItemSheet`'s "Discard changes?"/`SettingsView`'s "Delete your
        // account?"): system chrome, so Dynamic Type, VoiceOver, Reduce
        // Motion, and the 44pt tap-target floor all come for free. Only
        // "Continue" records consent; "Not now" (the dialog's own cancel
        // action) leaves the sheet exactly as the user left it — `rawText`
        // untouched, nothing sent.
        .confirmationDialog(
            "Send this text to AI?",
            isPresented: $isPresentingAIConsent,
            titleVisibility: .visible
        ) {
            Button("Continue") {
                AIImportConsent.grant()
                Task { await submit() }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(
                "To find your bookings, this text is sent to a third-party AI service (via Cloudflare) "
                    + "and used only to extract booking details \u{2014} it isn\u{2019}t stored afterward. "
                    + "You can add trips manually instead if you\u{2019}d rather not."
            )
        }
    }

    private var title: String { isReviewingPacking ? "Review packing list" : "Paste to import" }

    // MARK: - Paste box (initial state)

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(
                "Paste a booking confirmation, a day plan, a packing list, or any mix \u{2014} "
                    + "we\u{2019}ll sort out what goes where."
            )
            .font(Typo.body(Typo.Size.caption))
            .foregroundStyle(Palette.slate)

            TextEditor(text: $rawText)
                .frame(minHeight: 220)
                .font(Typo.body())
                .padding(Spacing.xs)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                        .stroke(Palette.mist, lineWidth: 1)
                }
                .disabled(isSubmitting)
                // A bare `TextEditor` otherwise reads as an unlabeled text
                // field — the instruction sentence above it explains what
                // to paste, but isn't itself attached to this control.
                .accessibilityLabel("Text to import")

            // PLAN.md: the on-device route never shares this text with
            // anyone, so its footer says so instead of the third-party
            // disclosure below — the remote route's existing copy already
            // covers that case (and its own consent dialog restates it),
            // so no NEW line is added there, only this one swapped.
            if currentRoute == .onDevice {
                Text("Processed on this iPhone \u{2014} text never leaves your device.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            } else {
                Text(
                    "Pasted text is sent to an AI service to find your bookings \u{2014} "
                        + "codes and notes aren\u{2019}t retained beyond that."
                )
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
            }

            if let noResultsMessage {
                Text(noResultsMessage)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.rose)
            }

            Button {
                switch currentRoute {
                case .onDevice:
                    Task { await submitOnDevice() }
                case .remote:
                    Task { await runRemoteImportFlow() }
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    if isSubmitting {
                        ProgressView().tint(canSubmit ? Palette.onAmber : Palette.slate)
                    }
                    Text(isSubmitting ? "Importing\u{2026}" : "Import")
                        .font(Typo.body(weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(canSubmit ? Palette.onAmber : Palette.slate)
                .padding(.vertical, Spacing.md)
                .background(
                    canSubmit ? Palette.amber : Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    // MARK: - Packing vetting checklist (post-extraction, if any packing items were found)

    private var packingReviewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if itineraryItemsCreated > 0 {
                Text(
                    "\(itineraryItemsCreated) item\(itineraryItemsCreated == 1 ? "" : "s") also added to your "
                        + "itinerary for review."
                )
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(CategoryColor.activity.fg)
            }

            if let partialFailureNote {
                Text(partialFailureNote)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.rose)
            }

            Text(
                "We found \(packingCandidates.count) packing item\(packingCandidates.count == 1 ? "" : "s") "
                    + "\u{2014} uncheck anything you don\u{2019}t want to add."
            )
            .font(Typo.body(Typo.Size.caption))
            .foregroundStyle(Palette.slate)

            VStack(spacing: Spacing.sm) {
                ForEach($packingCandidates) { $candidate in
                    packingCandidateRow($candidate)
                }
            }

            Button {
                onPackingConfirmed?(toAddCandidates)
                dismiss()
            } label: {
                Text("Add \(toAddCandidates.count) item\(toAddCandidates.count == 1 ? "" : "s")")
                    .font(Typo.body(weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(toAddCandidates.isEmpty ? Palette.slate : Palette.onAmber)
                    .padding(.vertical, Spacing.md)
                    .background(
                        toAddCandidates.isEmpty ? Palette.mist : Palette.amber,
                        in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(toAddCandidates.isEmpty)
        }
    }

    private func packingCandidateRow(_ candidate: Binding<PackingCandidate>) -> some View {
        HStack(spacing: Spacing.md) {
            Button {
                candidate.wrappedValue.isChecked.toggle()
            } label: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(candidate.wrappedValue.isChecked ? CategoryColor.activity.fg : Color.clear)
                    .frame(width: checkboxSide, height: checkboxSide)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(candidate.wrappedValue.isChecked ? Color.clear : Palette.mist, lineWidth: 2)
                    }
                    .overlay {
                        if candidate.wrappedValue.isChecked {
                            Image(systemName: "checkmark")
                                .font(.system(size: checkmarkSize, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            // This checkbox had no accessible label at all — VoiceOver read
            // either nothing or the checkmark glyph's own SF Symbol name,
            // depending on state. Mirrors `PackingListView`'s
            // reference-standard checkbox: label + checked state as a
            // value, not baked into the label.
            .accessibilityLabel(candidate.wrappedValue.label.isEmpty ? "Packing item" : candidate.wrappedValue.label)
            .accessibilityValue(candidate.wrappedValue.isChecked ? "Included" : "Excluded")
            .accessibilityAddTraits(candidate.wrappedValue.isChecked ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 2) {
                TextField("Item", text: candidate.label)
                    .font(Typo.body(Typo.Size.body, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    Image(systemName: candidate.wrappedValue.groupKey.symbolName)
                        .font(.system(size: groupIconSize, weight: .bold))
                        // Decorative — the group name right next to it says
                        // the same thing.
                        .accessibilityHidden(true)
                    Text(candidate.wrappedValue.groupKey.displayName)
                        .font(Typo.body(11, weight: .semibold))
                }
                .foregroundStyle(Palette.slate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .opacity(candidate.wrappedValue.isChecked ? 1 : 0.55)
    }

    // MARK: - Submit

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        noResultsMessage = nil
        partialFailureNote = nil
        let request = IngestTextRequest(tripId: tripId, rawText: trimmedText)
        do {
            let response: IngestTextResponse = try await Supa.invoke("ingest-text", params: request)
            let candidates = response.packingItems.map {
                PackingCandidate(label: $0.label, groupKey: PackingGroupKey(rawValue: $0.groupKey) ?? .custom)
            }
            handleImportOutcome(
                created: response.created, packingCandidates: candidates,
                itineraryFailed: response.itineraryFailed, packingFailed: response.packingFailed
            )
        } catch {
            isSubmitting = false
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    /// The Import button's `.remote`-route tap decision (Guideline
    /// 5.1.2(i)) — factored out so `submitOnDevice()` can fall back into
    /// the exact same gate rather than re-deriving it. `async` only because
    /// its caller already runs inside a `Task`; `.sendImmediately` awaits
    /// `submit()` directly instead of spawning a nested one.
    private func runRemoteImportFlow() async {
        switch AIImportConsent.tapOutcome() {
        case .sendImmediately:
            await submit()
        case .showConsentPrompt:
            isPresentingAIConsent = true
        }
    }

    /// On-device paste-import (PLAN.md). Reachable only when `currentRoute
    /// == .onDevice` at tap time — availability and the context-window
    /// pre-estimate were already checked there, but both guards below are
    /// repeated anyway: `#available`/`canImport` are per-call-site in
    /// Swift, not something an earlier check elsewhere satisfies.
    ///
    /// No consent dialog on this path, ever — pasted text stays on the
    /// device end to end. `OnDeviceExtractor.extractAll` already enforces
    /// PLAN.md's all-or-nothing rule (either sub-extraction hard-failing
    /// discards both), so `.fallback` here means "run the remote flow from
    /// scratch," identical to what a `.remote`-routed tap would have done —
    /// including its own consent gate, since a fallback is the one moment
    /// pasted text is about to leave the device on what the user believed
    /// was an on-device-only attempt.
    private func submitOnDevice() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        noResultsMessage = nil
        partialFailureNote = nil

        // Mirrors `AddItemSheet.save()`'s create-branch creator fallback
        // (Finding 1 there) — the signed-out local trip creator is still
        // entitled to add items (`TripView.canAddItems`), so this path must
        // resolve a creator the exact same way, not just prefer one that
        // happens to exist.
        guard let creatorId = authManager.userId ?? tripCreatedBy else {
            isSubmitting = false
            await runRemoteImportFlow()
            return
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch await OnDeviceExtractor.extractAll(from: trimmedText) {
            case .success(let items, let packing):
                let rows = items.compactMap(ImportExtraction.mapItemToRow)
                let created = insertValidatedItineraryItems(rows, creatorId: creatorId)
                let candidates = packing.compactMap { raw in
                    ImportExtraction.mapPackingItem(raw).map { PackingCandidate(label: $0.label, groupKey: $0.groupKey) }
                }
                // Both sub-extractions succeeded by construction here (a
                // hard failure on either side is the `.fallback` case
                // below) — `itineraryFailed`/`packingFailed` are always
                // false, matching PLAN.md's "no partial mixing."
                handleImportOutcome(created: created, packingCandidates: candidates, itineraryFailed: false, packingFailed: false)
            case .fallback:
                isSubmitting = false
                await runRemoteImportFlow()
            }
            return
        }
        #endif
        // Unreachable in practice (the button only calls this method when
        // `currentRoute == .onDevice`, which already implies both guards
        // above hold) — kept as a safe fallback rather than an assertion,
        // since "just try the remote path" is a correct response even to
        // an impossible state.
        isSubmitting = false
        await runRemoteImportFlow()
    }

    /// Local-insert half of the on-device path — mirrors
    /// `AddItemSheet.save()`'s create branch exactly (this milestone's
    /// brief: "reuse the exact path"): SwiftData insert on the main
    /// context, `try? modelContext.save()`, then `SyncEngine.enqueueUpsert`
    /// for the offline-first outbox — the same "insert then `try?` save,
    /// one row at a time" shape `PackingItem.insert` already uses for a
    /// batch import. `status = .suggested`/`source = .textImport` (not
    /// `.confirmed`/`.manual`) is the one difference from a manual add:
    /// these land in the exact review pipeline (`ImportReviewBanner`/
    /// `SuggestedItemsSheet`) email-import and remote paste-import
    /// suggestions already use. Returns the count actually inserted, for
    /// `handleImportOutcome`'s `created`.
    private func insertValidatedItineraryItems(
        _ rows: [ImportExtraction.ValidatedItineraryRow], creatorId: UUID
    ) -> Int {
        let now = Date()
        var created = 0
        for row in rows {
            let item = ItineraryItem(
                id: UUID(), tripId: tripId, categoryRaw: row.category.rawValue, title: row.title,
                startsAt: row.startsAt, endsAt: row.endsAt, tz: row.tz,
                locationName: row.locationName, locationLat: nil, locationLng: nil,
                confirmation: row.confirmation, notes: nil, detailsJSON: "{}",
                statusRaw: ItemStatus.suggested.rawValue, sourceRaw: ItemSource.textImport.rawValue,
                createdBy: creatorId, createdAt: now, updatedAt: now, updatedBy: nil
            )
            item.details = row.details
            modelContext.insert(item)
            try? modelContext.save()
            let dto = item.toDTO()
            let rowId = item.id
            let capturedTripId = tripId
            Task { await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: rowId, tripId: capturedTripId, payload: dto) }
            created += 1
        }
        return created
    }

    /// Shared UI-state transition once EITHER path — remote `ingest-text`
    /// or on-device `OnDeviceExtractor` — has a final result in this
    /// sheet's own currency (PLAN.md: "on-device path produces the SAME
    /// internal result shape the sheet already consumes"). Each path
    /// builds its own `[PackingCandidate]` its own way (remote: straight
    /// off the wire payload; on-device: through `ImportExtraction`'s
    /// validation) — this only decides what the user sees next, exactly
    /// the logic `submit()` used to inline before it had a second caller.
    private func handleImportOutcome(
        created: Int, packingCandidates newPackingCandidates: [PackingCandidate],
        itineraryFailed: Bool, packingFailed: Bool
    ) {
        isSubmitting = false
        itineraryItemsCreated = created
        // A remote response never has both flags true (see `submit()`'s
        // caller); the on-device path never sets either (see
        // `submitOnDevice()`'s caller).
        let failedNote: String? = itineraryFailed
            ? "Couldn\u{2019}t check for bookings or activities \u{2014} try again."
            : packingFailed
                ? "Couldn\u{2019}t check for a packing list \u{2014} try again."
                : nil

        if !newPackingCandidates.isEmpty {
            packingCandidates = newPackingCandidates
            partialFailureNote = failedNote
            // The checklist screen itself shows the itinerary count (see
            // `packingReviewSection`) — report it now since this sheet
            // won't dismiss until the checklist is confirmed.
            if created > 0 { onItineraryItemsImported?(created) }
        } else if created > 0 {
            onItineraryItemsImported?(created)
            if let failedNote {
                // Don't auto-dismiss when the other side may have silently
                // dropped something the user pasted — give them a chance
                // to see the note and retry.
                noResultsMessage = failedNote
            } else {
                dismiss()
            }
        } else if let failedNote {
            noResultsMessage = failedNote
        } else {
            noResultsMessage = "Couldn\u{2019}t find anything to import in that text. Try editing it, or paste something else."
        }
    }

    /// Maps `ingest-text`'s documented error responses (this milestone's
    /// brief) to one clear, friendly message each — never surfaces a raw
    /// status code or the server's internal error slug to the user.
    ///
    /// Testability gap: `static` (touches no `self` state) so
    /// `TriptoTests/PasteImportSheetFriendlyMessageTests.swift` can call it
    /// directly, same convention `WelcomeView.signInFailureMessage(for:)` /
    /// `appleSideFailureMessage(for:)` / `urlErrorCode(_:)` already use — a
    /// `private` instance method is file-scoped and un-callable even via
    /// `@testable import Tripto`.
    static func friendlyMessage(for error: Error) -> String {
        guard let functionsError = error as? FunctionsError else {
            return "Something went wrong. Check your connection and try again."
        }
        switch functionsError {
        case .relayError:
            return "Something went wrong. Check your connection and try again."
        case .httpError(let code, _):
            switch code {
            case 400:
                return "That didn\u{2019}t look like valid text. Try pasting it again."
            case 401:
                return "You\u{2019}re signed out, so this can\u{2019}t be imported right now. Sign back in and try again."
            case 404:
                return "Couldn\u{2019}t access that trip."
            case 429:
                return "You\u{2019}ve imported a lot recently \u{2014} try again in an hour."
            case 502:
                return "Couldn\u{2019}t process that text. Try again."
            default:
                return "Something went wrong. Try again."
            }
        }
    }
}

/// Apple Guideline 5.1.2(i) (rewritten 2025-11-13): explicit, affirmative
/// permission before sharing user data with a third-party AI — a passive
/// disclosure line alone no longer satisfies it. One `UserDefaults` bool,
/// remembered forever once granted (same injectable-`UserDefaults` recipe as
/// `PassEffects.isTornStub`/`setTornStub`, for the same reason: testable
/// without touching the real `UserDefaults.standard`).
///
/// `PasteImportSheet.submit()` — the only call site that actually reaches
/// the network — is reachable from exactly two places: `runRemoteImportFlow()`'s
/// `.sendImmediately` branch (itself reached only from the Import button's
/// `.remote`-route tap, or from `submitOnDevice()` falling back), and the
/// consent dialog's "Continue" button, which calls `grant()` immediately
/// before it. A not-yet-granted tap can therefore never reach the server
/// without the user first seeing and accepting the prompt — see
/// `AIImportConsentTests` for the pure (network-free) proof of that gate,
/// and `ImportRoutingTests` for the proof that an `.onDevice` route never
/// even reaches this decision.
enum AIImportConsent {
    private static let key = "aiImportConsentGranted"

    static func isGranted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func grant(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// The Import button's tap decision.
    enum TapOutcome: Equatable {
        case sendImmediately
        case showConsentPrompt
    }

    static func tapOutcome(defaults: UserDefaults = .standard) -> TapOutcome {
        isGranted(defaults: defaults) ? .sendImmediately : .showConsentPrompt
    }
}

/// `ingest-text`'s request body — plain camelCase, matching that function's
/// own `req.json()` shape exactly (see `Supa.invoke`'s doc comment for why
/// this is encoded without `JSONCoding`'s snake_case conversion). No `kind`
/// field anymore (TI-3) — the function always runs both extractions.
private struct IngestTextRequest: Encodable {
    let tripId: UUID
    let rawText: String
}

private struct IngestTextResponse: Decodable {
    struct PackingItemPayload: Decodable {
        let label: String
        let groupKey: String
    }
    let created: Int
    let packingItems: [PackingItemPayload]
    /// Review fix: lets the sheet tell "extraction ran and found nothing"
    /// apart from "extraction failed" — see `partialFailureNote`.
    let itineraryFailed: Bool
    let packingFailed: Bool
}

// No `#Preview` here (like every other `@Environment(AuthManager.self)`
// consumer in this codebase, e.g. `TripView`/`SuggestedItemsSheet` — only
// `RootView`'s own preview hand-builds the full auth/sync/router stack):
// this sheet now reads `authManager`/`modelContext`/`syncEngine` directly
// for the on-device path's local insert, so a bare
// `PasteImportSheet(tripId: UUID())` preview would fail at render time
// with no Observable `AuthManager` in the environment.
