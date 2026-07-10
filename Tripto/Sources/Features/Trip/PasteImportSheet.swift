import Supabase
import SwiftUI

/// TI-0→TI-3 (`docs/BUILD_PLAN.md`): the app-side half of paste-to-import —
/// a large free-text box the user pastes anything trip-related into
/// (a booking confirmation, a day plan, a packing list, or any mix),
/// submitted to `ingest-text` via `Supa.invoke`.
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

    @Environment(\.dismiss) private var dismiss
    @State private var rawText = ""
    @State private var isSubmitting = false
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
                Task { await submit() }
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
            isSubmitting = false
            itineraryItemsCreated = response.created
            // A 200 never has both flags true — the server only returns
            // one when the other extraction is expected to have run, and
            // returns a hard 502 (caught below, in `catch`) when both fail.
            let failedNote: String? = response.itineraryFailed
                ? "Couldn\u{2019}t check for bookings or activities \u{2014} try again."
                : response.packingFailed
                    ? "Couldn\u{2019}t check for a packing list \u{2014} try again."
                    : nil

            if !response.packingItems.isEmpty {
                packingCandidates = response.packingItems.map {
                    PackingCandidate(label: $0.label, groupKey: PackingGroupKey(rawValue: $0.groupKey) ?? .custom)
                }
                partialFailureNote = failedNote
                // The checklist screen itself shows the itinerary count
                // (see `packingReviewSection`) — report it now since this
                // sheet won't dismiss until the checklist is confirmed.
                if response.created > 0 { onItineraryItemsImported?(response.created) }
            } else if response.created > 0 {
                onItineraryItemsImported?(response.created)
                if let failedNote {
                    // Don't auto-dismiss when the other side may have
                    // silently dropped something the user pasted — give
                    // them a chance to see the note and retry.
                    noResultsMessage = failedNote
                } else {
                    dismiss()
                }
            } else if let failedNote {
                noResultsMessage = failedNote
            } else {
                noResultsMessage = "Couldn\u{2019}t find anything to import in that text. Try editing it, or paste something else."
            }
        } catch {
            isSubmitting = false
            errorMessage = Self.friendlyMessage(for: error)
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
            case 502:
                return "Couldn\u{2019}t process that text. Try again."
            default:
                return "Something went wrong. Try again."
            }
        }
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

#Preview {
    PasteImportSheet(tripId: UUID())
}
