import PhotosUI
import Supabase
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    var onItineraryItemsImported: ((Int) -> Void)?
    /// Called with the still-checked, possibly-edited rows once the user
    /// confirms the vetting checklist. This sheet never inserts anything
    /// itself — see the type's doc comment.
    var onPackingConfirmed: (([(label: String, groupKey: PackingGroupKey)]) -> Void)?
    /// The signed-out local trip creator's own uid (mirrors
    /// `AddItemSheet.tripCreatedBy`'s doc comment exactly) — the on-device
    /// path inserts suggested rows itself, through the same SwiftData +
    /// outbox path `AddItemSheet.save()` uses, so it needs the identical
    /// fallback creator id when `authManager.userId` is `nil`. `nil` is
    /// only reachable in practice if a future call site forgets to pass
    /// this; `submitOnDevice()` falls back to remote rather than inserting
    /// with no creator at all in that case.
    var tripCreatedBy: UUID?
    /// C2/C3 (`.claude/company/release-1.2/PLAN.md`): optional seam for
    /// "attach the original scanned file to the item it created" — `nil` at
    /// every EXISTING call site (default), which hides the review step's
    /// attach toggle entirely and leaves behavior byte-identical to before
    /// this milestone. `AttachmentService` (coder A, `Data/
    /// AttachmentService.swift`) conforms via the zero-behavior
    /// `extension AttachmentService: AttachmentAttaching {}` near the bottom
    /// of this file; wiring a real instance in at a call site (this trip's
    /// `modelContext`/`syncEngine`/uploader id) is integration work for
    /// whoever mounts this sheet, not this file's job.
    var attachmentAttacher: (any AttachmentAttaching)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    /// UX-5: the two picker buttons need to reflow to a `VStack` at
    /// accessibility sizes (same recipe as `AvatarPhotoPicker.topRowLayout`)
    /// rather than truncate side by side.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rawText = ""
    @State private var isSubmitting = false
    /// Guideline 5.1.2(i) (rewritten 2025-11-13): true while the AI-import
    /// consent dialog is up — shown instead of calling `submit()` directly
    /// the first time (see `AIImportConsent`), never again once consent is
    /// on record.
    @State private var isPresentingAIConsent = false
    /// Review fix (D1): true while the "couldn't process on this iPhone,
    /// send to the remote AI instead?" reconfirm dialog is up — shown only
    /// when `submitOnDevice()` falls back to remote AND the user already
    /// granted AI-import consent in a past session. A never-consented user
    /// falling back sees `isPresentingAIConsent` instead (see
    /// `runRemoteFallbackAfterOnDeviceFailure()`) — never both at once.
    @State private var isPresentingOnDeviceFallbackConfirm = false
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

    /// `processingModeRow`'s trailing chevron — same recipe as
    /// `ZonePicker`'s own chevron (the row this one's shape mirrors).
    @ScaledMetric(relativeTo: .caption) private var processingChevronSize: CGFloat = 11

    /// PLAN.md Addendum: the "Processing" row's persisted choice — read
    /// once at sheet creation (SwiftUI's own `@State` default-value
    /// timing), then kept in lockstep with `ImportProcessingMode.set(_:)`
    /// whenever the user picks a different `processingModeRow` entry, so
    /// `currentRoute` reflects the change immediately without re-reading
    /// `UserDefaults` on every render.
    @State private var processingMode: ImportProcessingMode = ImportProcessingMode.current()

    // MARK: - Scan-to-add batch state (C3, PLAN.md) — photos/PDF picked
    // beside the paste box. `pickerPhotoItems`/`isPresentingFileImporter`
    // are the two picker triggers; everything else tracks ONE in-flight
    // batch (both pickers share the same serial queue — `processBatch`'s
    // own guard refuses a second batch while one is already running).

    @State private var isPresentingPhotosPicker = false
    @State private var pickerPhotoItems: [PhotosPickerItem] = []
    @State private var isPresentingFileImporter = false
    @State private var isProcessingBatch = false
    /// "Reading 2 of 3…" — nil whenever no batch is in flight.
    @State private var batchProgressText: String?
    /// One friendly row per input OCR/PDF-extraction couldn't read — the
    /// batch continues past each of these rather than aborting (this
    /// milestone's brief: "batch continues").
    @State private var batchSkippedFileNames: [String] = []
    /// Resumed by the AI-consent dialog's own buttons in `body` — bridges
    /// that SwiftUI-driven confirmation into `processBatch`'s async loop so
    /// "once per batch" (this milestone's brief) reuses the exact same
    /// dialog/state the single-paste flow already has, rather than a second
    /// one. Only ever non-nil while `processBatch` is actively awaiting a
    /// decision.
    @State private var pendingConsentContinuation: CheckedContinuation<Bool, Never>?
    /// UX-4: which copy variant the AI-consent dialog shows — set right
    /// before each of its two trigger points (`runRemoteImportFlow`'s
    /// `.showConsentPrompt`, `requestCloudConsentIfNeeded`) flips
    /// `isPresentingAIConsent` on. A scan input's SOURCE FILE never leaves
    /// the device — only its extracted text does — which a plain paste's
    /// own copy doesn't need to say at all (there is no source file).
    @State private var consentDialogContext: ConsentDialogContext = .pastedText
    private enum ConsentDialogContext {
        case pastedText
        case scannedInput
    }

    @State private var pendingAttachment: PendingAttachment?
    /// "Attach original to the new item" toggle default (this milestone's
    /// brief: "default ON").
    @State private var attachSourceToNewItem = true
    /// UX-1/UX-2: true while `confirmReview()` awaits a cloud-routed
    /// attach's `pullTrip`/resolve/attach chain — keeps the review screen
    /// (and its toast surface) alive until that finishes, success or not,
    /// instead of `dismiss()`ing before a failure has anywhere to report to.
    @State private var isConfirmingReview = false
    /// UX-2: standard per-screen toast (`Design/Components/Toast.swift`) —
    /// this sheet had none before; attach failures on EITHER route now
    /// surface here rather than failing silently.
    @State private var toast: String?

    /// Captured once a batch (photo/PDF) import creates its first itinerary
    /// item, on EITHER route (UX-1) — `nil` only for a text-paste import
    /// (no source bytes to offer).
    private struct PendingAttachment {
        var target: PendingAttachmentTarget
        let data: Data
        let fileName: String
        let contentType: AttachmentContentType
    }

    /// On-device path: the actual local object — already on this device.
    /// Cloud path (UX-1, `ingest-text`'s `createdItemIds`): the row exists
    /// only server-side at capture time, so only its id is known up front —
    /// resolved to a live local `ItineraryItem` lazily, at confirm time
    /// (`resolveAttachTarget`'s direct point-read).
    private enum PendingAttachmentTarget {
        case local(ItineraryItem)
        case remoteId(UUID)
    }

    /// True once there's a results screen to show instead of the paste box —
    /// packing items to vet, and/or a pending attach offer from a batch
    /// import. A batch that produced ONLY itinerary items (no packing text
    /// at all — the common case for a single scanned boarding pass) still
    /// needs this screen when there's an attach toggle to show, where a
    /// packing-only gate would skip straight to dismiss.
    private var isReviewingResults: Bool {
        !packingCandidates.isEmpty || pendingAttachment != nil
    }
    private var trimmedText: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedText.isEmpty && !isSubmitting && !isProcessingBatch }

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
            mode: processingMode,
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
                        if isReviewingResults {
                            resultsReviewSection
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
        // PLAN.md Addendum: also a no-op when `currentRoute` isn't
        // `.onDevice` — e.g. mode is `.cloud` — so this never warms a
        // session the current routing has no intention of using.
        .onAppear {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), currentRoute == .onDevice {
                OnDeviceExtractor.prewarm()
            }
            #endif
        }
        // R-L3 (reviewer LOW): if this sheet is torn down while
        // `processBatch` is awaiting `requestCloudConsentIfNeeded`'s
        // continuation (the confirmationDialog is modal, so only reachable
        // via e.g. the sheet being force-dismissed by its owner), the
        // continuation would otherwise never resume — a suspended-Task leak
        // plus a `withCheckedContinuation` runtime warning. Resuming with
        // `false` (the same outcome as "Not now") is always safe here: it
        // just stops the batch from sending anything else to the cloud,
        // exactly as if the user had declined.
        .onDisappear {
            pendingConsentContinuation?.resume(returning: false)
            pendingConsentContinuation = nil
        }
        .toastOverlay($toast)
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
                // Task 2 (scan-to-add): a batch's `processOneBatchText` awaits
                // this decision via `requestCloudConsentIfNeeded` instead of
                // calling `submit()` itself (a batch item's text never lives
                // in `rawText`) — resuming its continuation IS this tap for
                // that flow. The single-paste flow never sets one, so it
                // falls through to the original `submit()` call unchanged.
                if let pendingConsentContinuation {
                    pendingConsentContinuation.resume(returning: true)
                    self.pendingConsentContinuation = nil
                } else {
                    Task { await submit() }
                }
            }
            Button("Not now", role: .cancel) {
                pendingConsentContinuation?.resume(returning: false)
                pendingConsentContinuation = nil
            }
        } message: {
            // Compliance (Nov-2025 Guideline 5.1.2(i) — NAMED pre-transmission
            // disclosure): "OpenAI" must change if backend's LLM_MODEL secret
            // changes (~/repos/backend/projects/tripto/RUNBOOK.md §5) —
            // ingest-text and ingest-email share that ONE secret, so a
            // provider switch means updating this string AND
            // ImportAddressCard's consent copy (Design/Components/
            // ImportAddressCard.swift) together. UX-4: a scanned input's
            // source photo/PDF never leaves the device — only text OCR'd
            // ON this iPhone is what reaches the cloud — so that variant
            // says so explicitly rather than reusing the plain-paste
            // wording, which has no source file to reassure about at all.
            switch consentDialogContext {
            case .pastedText:
                Text(
                    "To find your bookings, this text is sent to OpenAI, routed through our Cloudflare gateway, "
                        + "and used only to extract booking details \u{2014} it isn\u{2019}t stored afterward. "
                        + "You can add trips manually instead if you\u{2019}d rather not."
                )
            case .scannedInput:
                Text(
                    "To find your bookings, the photo or PDF is read on this iPhone and only the extracted "
                        + "text is sent to OpenAI, routed through our Cloudflare gateway \u{2014} it isn\u{2019}t "
                        + "stored afterward. You can add trips manually instead if you\u{2019}d rather not."
                )
            }
        }
        // Review fix (D1): `submitOnDevice()`'s on-device attempt hard-
        // failed after the footer already promised "text never leaves your
        // device" for this paste — reusing a past `AIImportConsent.grant()`
        // silently here would contradict that promise, so even an
        // already-consented user gets one explicit reconfirm before this
        // specific text goes to the third-party service. A never-consented
        // user never sees this dialog — they get the normal consent prompt
        // above instead (see `runRemoteFallbackAfterOnDeviceFailure()`).
        .confirmationDialog(
            "Couldn\u{2019}t process on this iPhone",
            isPresented: $isPresentingOnDeviceFallbackConfirm,
            titleVisibility: .visible
        ) {
            Button("Continue") {
                Task { await submit() }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            // Compliance: same provider as the dialog above — keep both in
            // sync with backend's LLM_MODEL (see that comment).
            Text(
                "Send the pasted text to OpenAI instead, routed through our Cloudflare gateway? "
                    + "(You can also switch to Cloud AI above.)"
            )
        }
    }

    private var title: String {
        guard isReviewingResults else { return "Paste to import" }
        return packingCandidates.isEmpty ? "Review import" : "Review packing list"
    }

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
                .disabled(isSubmitting || isProcessingBatch)
                // A bare `TextEditor` otherwise reads as an unlabeled text
                // field — the instruction sentence above it explains what
                // to paste, but isn't itself attached to this control.
                .accessibilityLabel("Text to import")

            inputPickerRow

            if let batchProgressText {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text(batchProgressText)
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.slate)
                }
                // One combined VoiceOver stop reading the progress text
                // itself, same recipe as `processingModeRow` below.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(batchProgressText)
            }

            batchSkippedSummary

            // PLAN.md Addendum: which line shows is keyed off the route's
            // REASON, not just on-device-vs-not — `ImportRouting
            // .footerVariant(for:)` is the single source of truth for this
            // selection (and is what `ImportExtractionTests` exercises
            // directly, with no view rendering involved).
            switch ImportRouting.footerVariant(for: currentRoute) {
            case .onDevicePromise:
                Text("Processed on this iPhone \u{2014} text never leaves your device.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            case .remoteDisclosure:
                Text(
                    "Pasted text is sent to an AI service to find your bookings \u{2014} "
                        + "codes and notes aren\u{2019}t retained beyond that."
                )
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
            case .tooLongHonesty:
                Text("Too long to process on this iPhone \u{2014} will use the AI service.")
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

            // PLAN.md Addendum: only when a real choice exists — "no fake
            // choice on incapable devices." A device where on-device
            // extraction isn't available at all always routes
            // `.remote(.unavailable)` regardless of the stored preference
            // (see `ImportRouting.route`), so offering the picker there
            // would be a control with no observable effect.
            if isOnDeviceAvailable {
                processingModeRow
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

    // MARK: - Batch input pickers (C3, PLAN.md — "Choose photos"/"Choose file")

    /// UX-5: the two buttons truncate side by side at accessibility sizes —
    /// same `isAccessibilitySize` -> `AnyLayout` swap `AvatarPhotoPicker
    /// .topRowLayout` established for its own avatar+field pair
    /// (`AvatarPhotoPicker.swift:79-83`), reflowing to a `VStack` instead.
    private var inputPickerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(spacing: Spacing.sm))
    }

    /// Two secondary affordances beside the paste box — mirrors
    /// `AvatarPhotoPicker`'s own pick-then-auto-process shape (no separate
    /// "start" button; selecting IS starting, via the `.onChange`/
    /// `.fileImporter` completion below).
    private var inputPickerRow: some View {
        inputPickerLayout {
            Button {
                isPresentingPhotosPicker = true
            } label: {
                inputPickerLabel(systemImage: "photo.on.rectangle", title: "Choose photos")
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || isProcessingBatch)
            .photosPicker(
                isPresented: $isPresentingPhotosPicker, selection: $pickerPhotoItems, maxSelectionCount: 5, matching: .images
            )
            .accessibilityHint("Import up to 5 photos of a booking or itinerary")

            Button {
                isPresentingFileImporter = true
            } label: {
                inputPickerLabel(systemImage: "doc.text.viewfinder", title: "Choose file")
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || isProcessingBatch)
            .accessibilityHint("Import a PDF booking or itinerary")
        }
        .fileImporter(
            isPresented: $isPresentingFileImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await processFileImporterSelection(urls) }
            }
        }
        .onChange(of: pickerPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await processPhotoPickerSelection(newItems) }
        }
    }

    private func inputPickerLabel(systemImage: String, title: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                // Decorative — the title right next to it already says the
                // same thing (same treatment as `packingCandidateRow`'s
                // group icon).
                .accessibilityHidden(true)
            Text(title)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
        .background(Palette.mist.opacity(0.5), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        .contentShape(Rectangle())
    }

    /// One row per input `processBatch` couldn't read — shown both here
    /// (`pasteSection`, e.g. a batch that found nothing at all) and in
    /// `resultsReviewSection` (a batch that found SOMETHING alongside these).
    /// `EmptyView` when there's nothing to report, so both call sites can
    /// include this unconditionally.
    @ViewBuilder
    private var batchSkippedSummary: some View {
        if !batchSkippedFileNames.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(batchSkippedFileNames, id: \.self) { fileName in
                    Text("Couldn\u{2019}t read \u{201C}\(fileName)\u{201D} \u{2014} skipped.")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                }
            }
        }
    }

    // MARK: - Processing mode row (only offered when a real choice exists)

    /// "Processing" row (PLAN.md Addendum) — same row shape as
    /// `ZonePicker` (label + trailing value + chevron), swapping its
    /// tap-to-sheet mechanic for a native two-entry `Menu`: Dynamic Type,
    /// VoiceOver, and the 44pt tap target all come from `Menu`/`Text` for
    /// free, same as every other control in this file. Only ever mounted
    /// by `pasteSection` when `isOnDeviceAvailable` — see that call site's
    /// comment for why a choice is never offered where it wouldn't do
    /// anything.
    private var processingModeRow: some View {
        Menu {
            ForEach(ImportProcessingMode.allCases, id: \.self) { mode in
                Button {
                    processingMode = mode
                    ImportProcessingMode.set(mode)
                } label: {
                    if mode == processingMode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("Processing")
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                Spacer()
                Text(processingMode.displayName)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: processingChevronSize, weight: .semibold))
                    .foregroundStyle(Palette.slate)
            }
            .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor, same as SegmentedControl's
            .contentShape(Rectangle())
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.mist.opacity(0.5), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        // Same "one combined VoiceOver stop, explicit label + value" recipe
        // as `packingCandidateRow`'s checkbox, instead of ZonePicker's
        // single-concatenated-string label — reads as "Processing. On this
        // iPhone. Button." rather than requiring a second swipe to reach
        // the chevron glyph or the value text.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing")
        .accessibilityValue(processingMode.displayName)
    }

    // MARK: - Results review (post-extraction: packing checklist and/or attach offer)

    /// Shown instead of `pasteSection` once `isReviewingResults` is true —
    /// originally just the packing vetting checklist; now also the (gated)
    /// attach-toggle screen for a batch that created itinerary items with no
    /// packing text at all. Either or both sections below may be empty for a
    /// given result; the confirm button at the bottom adapts to whichever
    /// combination actually applies (see `reviewConfirmLabel`).
    private var resultsReviewSection: some View {
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

            batchSkippedSummary

            if !packingCandidates.isEmpty {
                Text(
                    "We found \(packingCandidates.count) packing item\(packingCandidates.count == 1 ? "" : "s") "
                        + "\u{2014} uncheck anything you don\u{2019}t want to add."
                )
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)

                VStack(spacing: Spacing.sm) {
                    ForEach($packingCandidates) { $candidate in
                        PackingCandidateRow(candidate: $candidate)
                    }
                }
            }

            if attachmentAttacher != nil, pendingAttachment != nil {
                attachToggleRow
            }

            Button {
                Task { await confirmReview() }
            } label: {
                HStack(spacing: Spacing.sm) {
                    if isConfirmingReview {
                        ProgressView().tint(isReviewConfirmDisabled ? Palette.slate : Palette.onAmber)
                    }
                    Text(isConfirmingReview ? "Attaching\u{2026}" : reviewConfirmLabel)
                        .font(Typo.body(weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(isReviewConfirmDisabled ? Palette.slate : Palette.onAmber)
                .padding(.vertical, Spacing.md)
                .background(
                    isReviewConfirmDisabled ? Palette.mist : Palette.amber,
                    in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(isReviewConfirmDisabled)
        }
    }

    /// "Add N items" once there are still-checked packing candidates to
    /// insert; "Done" once this screen exists ONLY for the attach offer,
    /// with no packing checklist at all.
    private var reviewConfirmLabel: String {
        packingCandidates.isEmpty ? "Done" : "Add \(toAddCandidates.count) item\(toAddCandidates.count == 1 ? "" : "s")"
    }

    /// P-12 fix: a pending attach ALONE must keep Confirm enabled, even once
    /// every packing candidate has been unchecked — the original
    /// `!packingCandidates.isEmpty && toAddCandidates.isEmpty` check didn't
    /// know about `pendingAttachment` at all, so unchecking every packing
    /// suggestion on a batch that also had an attach offer disabled the
    /// ONLY button on screen with no way to finish. Also disabled while
    /// `confirmReview()` is in flight (same `isSubmitting`-folded-into-
    /// `canSubmit` shape the Import button already uses).
    private var isReviewConfirmDisabled: Bool {
        if isConfirmingReview { return true }
        guard pendingAttachment == nil else { return false }
        return !packingCandidates.isEmpty && toAddCandidates.isEmpty
    }

    /// "Attach original to the new item" — default ON (this milestone's
    /// brief). Native `Toggle`, same "platform control gives Dynamic
    /// Type/VoiceOver/44pt for free" recipe as every other control in this
    /// file.
    private var attachToggleRow: some View {
        Toggle(isOn: $attachSourceToNewItem) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attach original to the new item")
                    .font(Typo.body(Typo.Size.body, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if let pendingAttachment {
                    Text(pendingAttachment.fileName)
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .tint(Palette.amber)
        .padding(Spacing.md)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .accessibilityHint("Keeps a copy of the imported file on this item")
    }

    // MARK: - Submit

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        noResultsMessage = nil
        partialFailureNote = nil
        // P-10: a prior batch's skipped-file rows (`pasteSection` renders
        // them unconditionally) must not linger once the user switches back
        // to a plain paste and imports that instead.
        batchSkippedFileNames = []
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
            consentDialogContext = .pastedText
            isPresentingAIConsent = true
        }
    }

    /// Review fix (D1): `submitOnDevice()`'s equivalent of
    /// `runRemoteImportFlow()` for its own "falling back to remote" exits —
    /// deliberately NOT the same gate. The footer told the user this paste
    /// would be processed on-device; a fallback is the one moment that
    /// promise breaks, so a past `AIImportConsent.grant()` (from some
    /// earlier, unrelated remote import) may no longer speak for THIS text.
    /// A never-consented user still sees only the one normal consent
    /// dialog — granting it there both records consent and sends this
    /// text, so stacking a second "are you sure" on top of it would just be
    /// two dialogs for one decision.
    private func runRemoteFallbackAfterOnDeviceFailure() async {
        if AIImportConsent.isGranted() {
            isPresentingOnDeviceFallbackConfirm = true
        } else {
            isPresentingAIConsent = true
        }
    }

    /// On-device paste-import (PLAN.md). Reachable only when `currentRoute
    /// == .onDevice` at tap time — availability and the context-window
    /// pre-estimate were already checked there, but both guards below are
    /// repeated anyway: `#available`/`canImport` are per-call-site in
    /// Swift, not something an earlier check elsewhere satisfies.
    ///
    /// No consent dialog for the on-device attempt itself, ever — pasted
    /// text stays on the device end to end while this method is trying.
    /// Every exit below that instead falls back to remote (an unresolved
    /// creator, `.fallback` from `OnDeviceExtractor.extractAll`, or the
    /// impossible not-actually-available branch) goes through
    /// `runRemoteFallbackAfterOnDeviceFailure()`, NOT `runRemoteImportFlow()`
    /// directly — see that method's doc comment for why (review fix D1: an
    /// already-consented user still gets one explicit reconfirm here,
    /// since the footer just promised this text would stay on-device).
    private func submitOnDevice() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        noResultsMessage = nil
        partialFailureNote = nil
        batchSkippedFileNames = [] // P-10 — same reset as submit(), same reason

        // Mirrors `AddItemSheet.save()`'s create-branch creator fallback
        // (Finding 1 there) — the signed-out local trip creator is still
        // entitled to add items (`TripView.canAddItems`), so this path must
        // resolve a creator the exact same way, not just prefer one that
        // happens to exist.
        guard let creatorId = authManager.userId ?? tripCreatedBy else {
            isSubmitting = false
            await runRemoteFallbackAfterOnDeviceFailure()
            return
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch await OnDeviceExtractor.extractAll(from: trimmedText) {
            case .success(let items, let packing):
                let rows = items.compactMap(ImportExtraction.mapItemToRow)
                let (created, _) = insertValidatedItineraryItems(rows, creatorId: creatorId)
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
                await runRemoteFallbackAfterOnDeviceFailure()
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
        await runRemoteFallbackAfterOnDeviceFailure()
    }

    /// Local-insert half of the on-device path — mirrors
    /// `AddItemSheet.save()`'s create branch (this milestone's brief:
    /// "reuse the exact path"): SwiftData insert on the main context,
    /// `modelContext.save()`, then `SyncEngine.enqueueUpsert` for the
    /// offline-first outbox, one row at a time. Review fix (D3): a failed
    /// save is now a do/catch'd skip, matching `AddItemSheet.save()`'s own
    /// do/catch (Finding 2) instead of `PackingItem.insert`'s `try?` — the
    /// old `try?` let a failed row still get counted in the returned
    /// `created` total and enqueued to the sync outbox as a phantom upsert
    /// for a row that was never actually persisted. `status =
    /// .suggested`/`source = .textImport` (not `.confirmed`/`.manual`) is
    /// the one difference from a manual add: these land in the exact
    /// review pipeline (`ImportReviewBanner`/`SuggestedItemsSheet`)
    /// email-import and remote paste-import suggestions already use.
    /// Returns the count of rows actually persisted, for
    /// `handleImportOutcome`'s `created` — and (Task 3, PLAN.md) the FIRST
    /// row actually persisted, so a batch import can offer to attach its
    /// source bytes to it. `nil` when every row failed to save; unused by
    /// `submitOnDevice()`'s own call site (single-paste import has no source
    /// bytes to attach), read only by `processOneBatchText`.
    private func insertValidatedItineraryItems(
        _ rows: [ImportExtraction.ValidatedItineraryRow], creatorId: UUID
    ) -> (created: Int, firstItem: ItineraryItem?) {
        let now = Date()
        var created = 0
        var firstItem: ItineraryItem?
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
            do {
                try modelContext.save()
            } catch {
                // Skip this row rather than counting/enqueuing it — a
                // failed save must not inflate `created` or hand the sync
                // outbox a phantom upsert for a row that isn't actually on
                // disk. One bad row still doesn't sink the rest of the
                // batch (same "log and continue" rule
                // `ImportExtraction.mapItemToRow` already applies at the
                // validation stage).
                continue
            }
            let dto = item.toDTO()
            let rowId = item.id
            let capturedTripId = tripId
            Task { await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: rowId, tripId: capturedTripId, payload: dto) }
            created += 1
            if firstItem == nil { firstItem = item }
        }
        return (created, firstItem)
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
        itineraryFailed: Bool, packingFailed: Bool,
        emptyResultMessage: String = "Couldn\u{2019}t find anything to import in that text. Try editing it, or paste something else."
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
            // `resultsReviewSection`) — report it now since this sheet
            // won't dismiss until the checklist is confirmed.
            if created > 0 { onItineraryItemsImported?(created) }
        } else if created > 0 {
            onItineraryItemsImported?(created)
            if let failedNote {
                // Don't auto-dismiss when the other side may have silently
                // dropped something the user pasted — give them a chance
                // to see the note and retry.
                noResultsMessage = failedNote
            } else if !isReviewingResults {
                dismiss()
            }
            // else: `isReviewingResults` is true here only via a (gated)
            // `pendingAttachment` — `newPackingCandidates` is empty in this
            // branch — already set by `processBatch` before this call, so
            // stay open and let `resultsReviewSection` offer the attach
            // toggle before the user dismisses.
        } else if let failedNote {
            noResultsMessage = failedNote
        } else {
            noResultsMessage = emptyResultMessage
        }
    }

    // MARK: - Scan-to-add batch (C3, PLAN.md)

    /// One picked-but-not-yet-processed input for `processBatch` — an image
    /// (from `PhotosPicker`) or PDF (from `.fileImporter`), together with the
    /// original bytes/name a batch may later offer to attach (Task 3).
    private enum BatchInput {
        case image(fileName: String, data: Data)
        case pdf(fileName: String, data: Data)

        var fileName: String {
            switch self {
            case .image(let fileName, _), .pdf(let fileName, _): return fileName
            }
        }

        var data: Data {
            switch self {
            case .image(_, let data), .pdf(_, let data): return data
            }
        }

        var isPDF: Bool {
            if case .pdf = self { return true }
            return false
        }
    }

    private func processPhotoPickerSelection(_ items: [PhotosPickerItem]) async {
        defer { pickerPhotoItems = [] } // clears selection so re-picking the same assets later still fires `.onChange`
        var inputs: [BatchInput] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            inputs.append(.image(fileName: "Photo \(index + 1)", data: data))
        }
        await processBatch(inputs)
    }

    /// PDFs cap at 5 too (`.prefix`), the same ceiling as the photos picker —
    /// bounds worst-case serial processing time on a single "Choose file"
    /// pick, since `fileImporter` (unlike `PhotosPicker`) has no built-in
    /// max-selection option.
    private func processFileImporterSelection(_ urls: [URL]) async {
        var inputs: [BatchInput] = []
        for url in urls.prefix(5) {
            let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
            defer { if didAccessSecurityScope { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            inputs.append(.pdf(fileName: url.lastPathComponent, data: data))
        }
        await processBatch(inputs)
    }

    /// Entry point for BOTH pickers above — mirrors `submit()`/
    /// `submitOnDevice()`'s shape (guard, reset transient state, do the
    /// work, `handleImportOutcome`) but drives `ImportRouting`'s decision
    /// once PER ITEM instead of once for the whole call, since each
    /// image/PDF OCRs to its own text with its own length
    /// (`ImportContextBudget.textFits` varies per item even though
    /// `processingMode` itself is fixed for the whole batch).
    ///
    /// Serial by construction — `for` + `await`, never a `TaskGroup` — per
    /// this milestone's brief: Vision/Foundation Models both compete for the
    /// same on-device thermal & rate budget, so items never run concurrently.
    private func processBatch(_ inputs: [BatchInput]) async {
        guard !inputs.isEmpty, !isProcessingBatch, !isSubmitting else { return }
        isProcessingBatch = true
        errorMessage = nil
        noResultsMessage = nil
        partialFailureNote = nil
        batchSkippedFileNames = []
        defer {
            isProcessingBatch = false
            batchProgressText = nil
        }

        // Mirrors `submitOnDevice()`'s own creator fallback — `nil` here
        // just means every item routes remote (see `processOneBatchText`'s
        // `let creatorId` guard), never a crash.
        let creatorId = authManager.userId ?? tripCreatedBy

        var totalCreated = 0
        var aggregatedPacking: [PackingCandidate] = []
        var anyItineraryFailed = false
        var anyPackingFailed = false
        var consentDeclined = false
        var firstAttachCandidate: (target: PendingAttachmentTarget, input: BatchInput)?

        for (index, input) in inputs.enumerated() {
            // "Not now" on the mid-batch consent dialog (`requestCloudConsentIfNeeded`)
            // stops sending anything else in THIS batch to the cloud —
            // mirrors the single-paste dialog's own "Not now leaves nothing
            // sent" rule, just applied to the rest of the queue instead of
            // one paste. Checked BEFORE touching `batchProgressText` so a
            // decline doesn't flash a "Reading N of M…" for an item that's
            // actually about to be skipped.
            if consentDeclined { break }
            batchProgressText = "Reading \(index + 1) of \(inputs.count)\u{2026}"

            let extractedText: String
            do {
                switch input {
                case .image(_, let data):
                    // S-2 (security review): a bounded ImageIO thumbnail
                    // decode, never a full-resolution `UIImage(data:)` —
                    // `OCRService.decodedImage` already bakes in EXIF
                    // orientation, so no separate orientation lookup here.
                    guard let cgImage = OCRService.decodedImage(from: data) else { throw OCRService.OCRError.invalidImage }
                    extractedText = try await OCRService.extractText(from: cgImage)
                case .pdf(_, let data):
                    extractedText = try await PDFTextExtractor.extractText(from: data)
                }
            } catch {
                batchSkippedFileNames.append(input.fileName)
                continue
            }

            let trimmedExtractedText = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty-OCR result — this milestone's brief: friendly row, batch
            // continues (not an error; a blank photo just has nothing to add).
            guard !trimmedExtractedText.isEmpty else {
                batchSkippedFileNames.append(input.fileName)
                continue
            }

            guard let outcome = await processOneBatchText(trimmedExtractedText, creatorId: creatorId) else {
                consentDeclined = true
                continue
            }

            totalCreated += outcome.created
            aggregatedPacking.append(contentsOf: outcome.packingCandidates)
            anyItineraryFailed = anyItineraryFailed || outcome.itineraryFailed
            anyPackingFailed = anyPackingFailed || outcome.packingFailed

            // UX-1: both routes are now candidates — on-device gives a local
            // object directly; cloud gives an id that resolves later
            // (`resolveAttachTarget`, at confirm time).
            if firstAttachCandidate == nil {
                if let firstItem = outcome.firstCreatedItem {
                    firstAttachCandidate = (.local(firstItem), input)
                } else if let firstId = outcome.firstCreatedItemId {
                    firstAttachCandidate = (.remoteId(firstId), input)
                }
            }
        }

        if let firstAttachCandidate {
            // Raw picked bytes, not pre-re-encoded — `AttachmentService
            // .attach` already re-encodes any `.jpeg`-content-typed payload
            // through `ImageProcessing.downsampledJPEG` internally (2400px/
            // q0.85, PLAN.md C1), regardless of the source format
            // (`CGImageSourceCreateWithData` reads HEIC/PNG/JPEG alike), so
            // handing it the original bytes here is correct as-is — no
            // separate re-encode step belongs in this file.
            pendingAttachment = PendingAttachment(
                target: firstAttachCandidate.target,
                data: firstAttachCandidate.input.data,
                fileName: firstAttachCandidate.input.fileName,
                contentType: firstAttachCandidate.input.isPDF ? .pdf : .jpeg
            )
        }

        handleImportOutcome(
            created: totalCreated, packingCandidates: aggregatedPacking,
            itineraryFailed: anyItineraryFailed, packingFailed: anyPackingFailed,
            emptyResultMessage: "Couldn\u{2019}t find anything to import in those files."
        )
    }

    private struct BatchTextOutcome {
        var created: Int
        var packingCandidates: [PackingCandidate]
        var itineraryFailed: Bool
        var packingFailed: Bool
        /// On-device branch only: the actual local object.
        var firstCreatedItem: ItineraryItem?
        /// UX-1: cloud branch only — `ingest-text`'s `createdItemIds.first`.
        /// Exactly one of these two fields is ever non-nil for a
        /// `created > 0` outcome.
        var firstCreatedItemId: UUID?
    }

    /// Routes ONE already-extracted text (from an OCR'd photo or PDF page)
    /// through the exact same `ImportRouting`/`OnDeviceExtractor`/
    /// `ingest-text` decision `submit()`/`submitOnDevice()` use for
    /// `rawText` — the "EXISTING ImportExtraction flow unchanged" this
    /// milestone's brief requires; only the text's SOURCE differs (OCR
    /// output vs. a direct paste).
    ///
    /// Deliberately skips `submitOnDevice()`'s own extra "couldn't process
    /// on this iPhone, reconfirm before sending to the AI service?" dialog
    /// on a `.fallback` (falls straight through to `sendToRemote` instead) —
    /// that dialog exists because `pasteSection`'s footer makes an explicit
    /// on-device PROMISE before the user taps Import; a batch import makes
    /// no equivalent per-item promise, and pausing a "Reading N of M…"
    /// progress loop for a second modal per fallback would be worse UX for a
    /// rare case. The `AIImportConsent` gate below still always fires before
    /// any upload either way — nothing here ever skips consent, only the
    /// extra reconfirm.
    ///
    /// Returns `nil` when this text needed the cloud path and the user
    /// declined consent (`requestCloudConsentIfNeeded`) — `processBatch`
    /// stops sending anything else in this batch to the cloud when that
    /// happens.
    private func processOneBatchText(_ text: String, creatorId: UUID?) async -> BatchTextOutcome? {
        let route = ImportRouting.route(
            mode: processingMode, isOnDeviceAvailable: isOnDeviceAvailable, textFitsOnDevice: ImportContextBudget.textFits(text)
        )

        if route == .onDevice, let creatorId {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                switch await OnDeviceExtractor.extractAll(from: text) {
                case .success(let items, let packing):
                    let rows = items.compactMap(ImportExtraction.mapItemToRow)
                    let (created, firstItem) = insertValidatedItineraryItems(rows, creatorId: creatorId)
                    let candidates = packing.compactMap { raw in
                        ImportExtraction.mapPackingItem(raw).map { PackingCandidate(label: $0.label, groupKey: $0.groupKey) }
                    }
                    return BatchTextOutcome(
                        created: created, packingCandidates: candidates,
                        itineraryFailed: false, packingFailed: false, firstCreatedItem: firstItem, firstCreatedItemId: nil
                    )
                case .fallback:
                    break // falls through to the remote send below
                }
            }
            #endif
        }

        return await sendToRemote(text)
    }

    private func sendToRemote(_ text: String) async -> BatchTextOutcome? {
        guard await requestCloudConsentIfNeeded() else { return nil }
        let request = IngestTextRequest(tripId: tripId, rawText: text)
        do {
            let response: IngestTextResponse = try await Supa.invoke("ingest-text", params: request)
            let candidates = response.packingItems.map {
                PackingCandidate(label: $0.label, groupKey: PackingGroupKey(rawValue: $0.groupKey) ?? .custom)
            }
            // UX-1: `createdItemIds` is insertion order, first = primary
            // (navbytes/backend#18) — the same "first row actually
            // persisted" convention `insertValidatedItineraryItems` already
            // uses for the on-device side. `?.first` (not `.first`): the
            // field is optional (contract discipline — see its own doc
            // comment), so an older/rolled-back function response with no
            // `createdItemIds` key at all just means no attach offer this
            // time, not a decode failure for the whole response.
            return BatchTextOutcome(
                created: response.created, packingCandidates: candidates,
                itineraryFailed: response.itineraryFailed, packingFailed: response.packingFailed,
                firstCreatedItem: nil, firstCreatedItemId: response.createdItemIds?.first
            )
        } catch {
            // One item's send failing doesn't sink the batch (same "log and
            // continue" rule the rest of this file already applies) — rolls
            // up into the aggregate `itineraryFailed`, which reuses the
            // EXISTING "couldn't check for bookings" note
            // (`handleImportOutcome`) rather than inventing new copy.
            return BatchTextOutcome(
                created: 0, packingCandidates: [], itineraryFailed: true, packingFailed: false,
                firstCreatedItem: nil, firstCreatedItemId: nil
            )
        }
    }

    /// Bridges the existing `AIImportConsent` dialog (SwiftUI-state-driven)
    /// into this `async` loop — `processOneBatchText` awaits the user's tap
    /// instead of the dialog's own button action re-entering `submit()` the
    /// way the single-paste flow does (see `body`'s "Continue"/"Not now"
    /// actions). Returns immediately (no dialog shown) once consent is
    /// already on record, which is what makes this "once per batch" (this
    /// milestone's brief): the first item that needs it is the only one that
    /// ever waits.
    private func requestCloudConsentIfNeeded() async -> Bool {
        if AIImportConsent.isGranted() { return true }
        consentDialogContext = .scannedInput
        return await withCheckedContinuation { continuation in
            pendingConsentContinuation = continuation
            isPresentingAIConsent = true
        }
    }

    /// `resultsReviewSection`'s confirm button — packing insert is
    /// synchronous/unconditional (unchanged), then, only when there's a real
    /// attach to attempt (toggle ON, a pending target, an attacher
    /// injected), AWAITS it before dismissing: UX-1/UX-2 need this sheet to
    /// still be alive (for `toast`/`resolveAttachTarget`'s network read)
    /// when an attach fails, which a fire-and-forget `Task` racing an
    /// immediate `dismiss()` can't guarantee. Every other case (no attach to
    /// make) dismisses immediately, byte-identical to before.
    private func confirmReview() async {
        if !packingCandidates.isEmpty {
            onPackingConfirmed?(toAddCandidates)
        }
        guard attachSourceToNewItem, let pendingAttachment, let attacher = attachmentAttacher else {
            dismiss()
            return
        }

        isConfirmingReview = true
        defer { isConfirmingReview = false }
        do {
            let item = try await resolveAttachTarget(pendingAttachment.target)
            try await attacher.attach(
                data: pendingAttachment.data, contentType: pendingAttachment.contentType,
                fileName: pendingAttachment.fileName, to: item
            )
            dismiss()
        } catch {
            // UX-2: never silent on either route — standard toast, same
            // surface every other screen uses. The itinerary item itself
            // was already created and already reported via
            // `onItineraryItemsImported` regardless, so this failure never
            // blocks or undoes the import it rode along with; the user
            // stays on this screen to see why, rather than losing the
            // message to an already-dismissed sheet.
            toast = "Couldn\u{2019}t attach \u{201C}\(pendingAttachment.fileName)\u{201D} to the new item."
            // A second tap of this same button should just dismiss, not
            // repeat a failed attempt automatically.
            attachSourceToNewItem = false
        }
    }

    /// UX-1 fix round (MED reentrancy): on-device targets resolve instantly
    /// (already local, no network). Cloud targets (`ingest-text`'s
    /// `createdItemIds.first`) used to go through `syncEngine.pullTrip`, but
    /// that method no-ops against an already-in-flight pull for the same
    /// trip (`SyncEngine`'s own `pullingTrips` self-guard) — both the
    /// original call AND its retry could land during someone else's
    /// unrelated in-flight pull and miss the just-created row entirely,
    /// producing a spurious "couldn't attach" toast for an item that lands
    /// moments later anyway. A direct point-read of this ONE row instead —
    /// the exact `select().eq("id", value:).single()` shape
    /// `SyncEngine+ShareLinks.insertAndReadBack` already uses for the same
    /// "read the row this device's own write just created" need (RLS scopes
    /// it identically to `pullTrip`'s own `itinerary_items` query) — has no
    /// dependency on any pull's timing: `ingest-text` already committed the
    /// insert before this method is ever reached, so the row is always
    /// there to read. No retry needed, and per this fix round: no sleeps.
    private func resolveAttachTarget(_ target: PendingAttachmentTarget) async throws -> ItineraryItem {
        switch target {
        case .local(let item):
            return item
        case .remoteId(let id):
            let dto: ItineraryItemDTO = try await Supa.client.from(SyncTable.itineraryItems.rawValue)
                .select().eq("id", value: id).single().execute().value
            if let existing = try fetchLocalItineraryItem(id: id) {
                existing.apply(dto)
                try modelContext.save()
                return existing
            }
            // Mirrors a pull's own apply-only behavior (`SyncStore
            // .applyItineraryItems`) — never `syncEngine.enqueueUpsert` this:
            // the row already exists server-side (this IS that row), so
            // re-enqueueing it would just push an unmodified duplicate
            // upsert of a write this device never actually authored.
            let item = ItineraryItem(dto: dto)
            modelContext.insert(item)
            try modelContext.save()
            return item
        }
    }

    private func fetchLocalItineraryItem(id: UUID) throws -> ItineraryItem? {
        try modelContext.fetch(FetchDescriptor<ItineraryItem>(predicate: #Predicate { $0.id == id })).first
    }

    /// Maps `ingest-text`'s documented error responses (this milestone's
    /// brief) to one clear, friendly message each — never surfaces a raw
    /// status code or the server's internal error slug to the user. The
    /// shared generic-fallback skeleton lives in `FriendlyFunctionsMessage`
    /// (DRY finding L5); only these per-code strings are genuinely this
    /// endpoint's own.
    ///
    /// Testability gap: `static` (touches no `self` state) so
    /// `TriptoTests/PasteImportSheetFriendlyMessageTests.swift` can call it
    /// directly, same convention `WelcomeView.signInFailureMessage(for:)` /
    /// `appleSideFailureMessage(for:)` / `urlErrorCode(_:)` already use — a
    /// `private` instance method is file-scoped and un-callable even via
    /// `@testable import Tripto`.
    static func friendlyMessage(for error: Error) -> String {
        FriendlyFunctionsMessage.map(error, perCode: [
            400: "That didn\u{2019}t look like valid text. Try pasting it again.",
            401: "You\u{2019}re signed out, so this can\u{2019}t be imported right now. Sign back in and try again.",
            404: "Couldn\u{2019}t access that trip.",
            429: "You\u{2019}ve imported a lot recently \u{2014} try again in an hour.",
            502: "Couldn\u{2019}t process that text. Try again."
        ])
    }
}

/// PLAN.md Addendum (client-decided): users may prefer the third-party
/// cloud AI even when on-device extraction is available on this device —
/// e.g. they find it more accurate, or just don't want to wait on a local
/// model. Two modes only, no third "never cloud" mode: refusing cloud sends
/// entirely is already `AIImportConsent`'s job below (declining that dialog
/// just leaves the paste unsent), so this preference only ever chooses
/// between two paths that both complete the import. Same injectable-
/// `UserDefaults` recipe as `AIImportConsent`/`EmailImportConsent`
/// (`TripImportAddress.swift`), for the same reason: testable without
/// touching the real `UserDefaults.standard`.
///
/// Read live by `currentRoute` (via `ImportRouting.route`) on every render,
/// and by `processingModeRow`'s `Menu` to show/persist the current choice —
/// changing it only changes ROUTING, never what `OnDeviceExtractor`/
/// `ingest-text` each do once reached.
enum ImportProcessingMode: String, CaseIterable {
    case onDevice
    case cloud

    private static let key = "importProcessingMode"

    var displayName: String {
        switch self {
        case .onDevice: return "On this iPhone"
        case .cloud: return "Cloud AI"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> ImportProcessingMode {
        defaults.string(forKey: key).flatMap(ImportProcessingMode.init(rawValue:)) ?? .onDevice
    }

    static func set(_ mode: ImportProcessingMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
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
/// the network — is reachable from exactly three places: `runRemoteImportFlow()`'s
/// `.sendImmediately` branch (reached only from the Import button's
/// `.remote`-route tap — `submitOnDevice()` falling back never dispatches
/// through here, see `runRemoteFallbackAfterOnDeviceFailure()`), the
/// consent dialog's "Continue" button (calls `grant()` immediately before
/// it), and the on-device-fallback reconfirm dialog's "Continue" button
/// (consent is already on record from a past session; that dialog exists
/// only to reconfirm THIS send after the on-device promise didn't hold).
/// A not-yet-granted tap can therefore never reach the server without the
/// user first seeing and accepting a prompt — see `AIImportConsentTests`
/// for the pure (network-free) proof of that gate, and
/// `ImportExtractionTests` for the proof that an `.onDevice` route never
/// even reaches this decision on its own attempt.
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

/// C2/C3 (`.claude/company/release-1.2/PLAN.md`): the seam `PasteImportSheet`
/// uses to offer "Attach original to the new item" after a scan-to-add
/// (photo/PDF) import — owned here (coder B), implemented by coder A's
/// `AttachmentService` (`Data/AttachmentService.swift`). Initially written
/// (and briefly shipped behind a `TRIPTO_ATTACHMENTS` flag) before
/// `AttachmentContentType`/`ItemAttachment` existed in-tree; both landed
/// during this same milestone, confirmed to match this protocol's shape
/// exactly, so the flag was removed again — this is now real, compiled,
/// tested code, not a placeholder.
protocol AttachmentAttaching {
    @discardableResult
    func attach(
        data: Data, contentType: AttachmentContentType, fileName: String, to item: ItineraryItem
    ) async throws -> ItemAttachment
}

/// `AttachmentService.attach`'s signature already matches
/// `AttachmentAttaching` exactly (see that type's own doc comment, which
/// anticipated this exact one-line conformance from whichever side landed
/// second) — a zero-behavior extension, not a reimplementation. Lives here
/// rather than in `Data/AttachmentService.swift` (coder A's exclusive file,
/// PLAN.md ownership) since Swift extensions may declare a type's
/// conformance to a protocol from any file in the same module.
extension AttachmentService: AttachmentAttaching {}

/// `ingest-text`'s request body — plain camelCase, matching that function's
/// own `req.json()` shape exactly (see `Supa.invoke`'s doc comment for why
/// this is encoded without `JSONCoding`'s snake_case conversion). No `kind`
/// field anymore (TI-3) — the function always runs both extractions.
private struct IngestTextRequest: Encodable {
    let tripId: UUID
    let rawText: String
}

/// `internal` (not `private`, unlike its sibling `IngestTextRequest` above)
/// so `IngestTextResponseDecodingTests` can decode it directly via
/// `@testable import Tripto` — a plain data-only `Decodable`, no behavior to
/// protect by hiding it.
struct IngestTextResponse: Decodable {
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
    /// UX-1 (navbytes/backend#18, additive): insertion order, first =
    /// primary itinerary item — lets a cloud-routed scan-to-add batch offer
    /// auto-attach too (`sendToRemote`/`resolveAttachTarget`), which used to
    /// be impossible with no created-row id at all in this response.
    ///
    /// Optional, NOT required (§3.6 contract discipline: additive-field
    /// tolerance) — a rollback/redeploy of `ingest-text` from a pre-#18 ref
    /// must not fail `Decodable` with `keyNotFound` and break cloud
    /// text-import entirely; a missing key here just means the attach offer
    /// doesn't fire for that response (`sendToRemote` reads `?.first`).
    let createdItemIds: [UUID]?
}

// No `#Preview` here (like every other `@Environment(AuthManager.self)`
// consumer in this codebase, e.g. `TripView`/`SuggestedItemsSheet` — only
// `RootView`'s own preview hand-builds the full auth/sync/router stack):
// this sheet now reads `authManager`/`modelContext`/`syncEngine` directly
// for the on-device path's local insert, so a bare
// `PasteImportSheet(tripId: UUID())` preview would fail at render time
// with no Observable `AuthManager` in the environment.
