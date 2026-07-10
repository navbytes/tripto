import Supabase
import SwiftUI

/// TI-2 (`docs/BUILD_PLAN.md`): the app-side half of paste-to-import — a
/// large free-text box the user pastes a booking confirmation or a packing
/// list into, submitted to the already-deployed `ingest-text` Edge Function
/// (`~/repos/backend/projects/tripto/functions/ingest-text`) via
/// `Supa.invoke`. Two call sites share this one sheet, parameterized by
/// `kind`:
///   - Booking (`ItineraryTabView.importTeaser` / `ShareTripView.importCard`,
///     "Or paste text instead" beside the email-import address card): the
///     function inserts `status: "suggested"` itinerary items server-side
///     (same review pipeline as email import — `ImportReviewBanner`/
///     `SuggestedItemsSheet` pick them up on their own), so this sheet never
///     touches SwiftData for booking imports — it only reports the created
///     count back via `onBookingImported` so the caller (which already owns
///     a `toast` state) can show it.
///   - Packing (`PackingListView`'s FAB confirmation dialog, "Paste a
///     list"): `ingest-text` does *not* write to the DB for packing (the app
///     already has an offline-first insert path) — it only extracts and
///     normalizes items. This sheet renders them as a pre-checked vetting
///     checklist so the user can drop anything mis-extracted before
///     confirming, then hands the still-checked rows to `onPackingConfirmed`
///     so the caller inserts each one through its own
///     `addItem(label:groupKey:assigneeProfileId:)` path — same "sheet is a
///     dumb form, caller owns the writes" split `PackingItemFormSheet`
///     already uses.
struct PasteImportSheet: View {
    enum Kind: Equatable {
        case booking
        case packing

        /// The exact wire value `ingest-text` expects (`index.ts`'s
        /// `body.kind === "booking" || body.kind === "packing"` check) —
        /// kept distinct from the Swift case names so a rename of one never
        /// silently breaks the other.
        var wireValue: String {
            switch self {
            case .booking: return "booking"
            case .packing: return "packing"
            }
        }
    }

    let kind: Kind
    let tripId: UUID
    /// Booking only: called once with the created count right before this
    /// sheet dismisses itself (a non-zero result). The caller shows the
    /// "toast + banner" (plan decision) — `ImportReviewBanner` on `TripView`
    /// picks up the new suggested items on its own once they sync in.
    var onBookingImported: ((Int) -> Void)? = nil
    /// Packing only: called with the still-checked, possibly-edited rows
    /// once the user confirms the vetting checklist. This sheet never
    /// inserts anything itself — see the type's doc comment.
    var onPackingConfirmed: (([(label: String, groupKey: PackingGroupKey)]) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var rawText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Non-nil once a 200 response came back with nothing found
    /// (`created: 0` / `items: []`) — not an error (this milestone's brief:
    /// "a 200 response with created: 0 ... is NOT an error"), just an
    /// invitation to edit and retry.
    @State private var noResultsMessage: String?
    /// Non-empty once a packing extraction found something — swaps the
    /// sheet's body from the paste box to the vetting checklist.
    @State private var packingCandidates: [PackingCandidate] = []

    private struct PackingCandidate: Identifiable {
        let id = UUID()
        var label: String
        let groupKey: PackingGroupKey
        var isChecked = true
    }

    private var isReviewingPacking: Bool { kind == .packing && !packingCandidates.isEmpty }
    private var trimmedText: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedText.isEmpty && !isSubmitting }
    /// Nit: the checked rows that will actually become packing items — a
    /// candidate edited down to an empty/whitespace-only label is dropped
    /// here rather than handed to `onPackingConfirmed`, where
    /// `PackingListView.addItem`'s own `!label.isEmpty` guard would silently
    /// no-op it while the confirm button's count still claimed it'd be
    /// added.
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

    private var title: String {
        switch kind {
        case .booking: return "Paste a booking"
        case .packing: return isReviewingPacking ? "Review packing list" : "Paste a packing list"
        }
    }

    // MARK: - Paste box (both kinds, initial state)

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(promptText)
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
                // Bug fix: `onAmber` is a fixed near-black, deliberately
                // non-adaptive to stay readable against `amber` (also
                // fixed) — see its doc comment. Blanket `.opacity(0.5)` on
                // the whole button used to fade this near-black text toward
                // the dark-mode page background instead of toward anything
                // legible, making disabled CTAs unreadable in dark mode.
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

    private var promptText: String {
        switch kind {
        case .booking:
            return "Paste a confirmation email or booking text below \u{2014} we\u{2019}ll pull out the flight, "
                + "stay, or reservation details for you to review."
        case .packing:
            return "Paste a packing list below \u{2014} one item per line works best."
        }
    }

    // MARK: - Packing vetting checklist (packing only, post-extraction)

    private var packingReviewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(
                "We found \(packingCandidates.count) item\(packingCandidates.count == 1 ? "" : "s") "
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
                    .frame(width: 24, height: 24)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(candidate.wrappedValue.isChecked ? Color.clear : Palette.mist, lineWidth: 2)
                    }
                    .overlay {
                        if candidate.wrappedValue.isChecked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Item", text: candidate.label)
                    .font(Typo.body(Typo.Size.body, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    Image(systemName: candidate.wrappedValue.groupKey.symbolName)
                        .font(.system(size: 10, weight: .bold))
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
        let request = IngestTextRequest(tripId: tripId, rawText: trimmedText, kind: kind.wireValue)
        do {
            switch kind {
            case .booking:
                let response: IngestTextBookingResponse = try await Supa.invoke("ingest-text", params: request)
                isSubmitting = false
                if response.created > 0 {
                    onBookingImported?(response.created)
                    dismiss()
                } else {
                    noResultsMessage = "Couldn\u{2019}t find a booking in that text. Try editing it, or paste something else."
                }
            case .packing:
                let response: IngestTextPackingResponse = try await Supa.invoke("ingest-text", params: request)
                isSubmitting = false
                if response.items.isEmpty {
                    noResultsMessage =
                        "Couldn\u{2019}t find a packing list in that text. Try editing it, or paste something else."
                } else {
                    packingCandidates = response.items.map {
                        PackingCandidate(label: $0.label, groupKey: PackingGroupKey(rawValue: $0.groupKey) ?? .custom)
                    }
                }
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
/// this is encoded without `JSONCoding`'s snake_case conversion).
private struct IngestTextRequest: Encodable {
    let tripId: UUID
    let rawText: String
    let kind: String
}

private struct IngestTextBookingResponse: Decodable {
    let created: Int
}

private struct IngestTextPackingResponse: Decodable {
    struct Item: Decodable {
        let label: String
        let groupKey: String
    }
    let items: [Item]
}

#Preview {
    PasteImportSheet(kind: .packing, tripId: UUID())
}
