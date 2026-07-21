import SwiftUI

/// One AI-suggested-or-extracted packing item awaiting the user's vet
/// (checked/unchecked + editable label) before it becomes a real
/// `PackingItem` — shared shape for `PasteImportSheet`'s paste-import
/// checklist and `PackingSuggestionsSheet`'s AI-suggestion checklist (both
/// "vet before insert," never auto-inserted).
struct PackingCandidate: Identifiable {
    let id = UUID()
    var label: String
    let groupKey: PackingGroupKey
    var isChecked = true
}

/// Checkbox + editable label + group tag for one `PackingCandidate` —
/// extracted from `PasteImportSheet`'s original private `packingCandidateRow`
/// (zero visual change) so `PackingSuggestionsSheet` renders the identical
/// vetting row instead of a second hand-rolled copy.
struct PackingCandidateRow: View {
    @Binding var candidate: PackingCandidate

    /// Checkbox container + its checkmark glyph, and the group-tag icon —
    /// see the shared `@ScaledMetric` recipe used throughout Features/Trip.
    @ScaledMetric(relativeTo: .body) private var checkboxSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var checkmarkSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var groupIconSize: CGFloat = 10

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button {
                candidate.isChecked.toggle()
            } label: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(candidate.isChecked ? CategoryColor.activity.fg : Color.clear)
                    .frame(width: checkboxSide, height: checkboxSide)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(candidate.isChecked ? Color.clear : Palette.mist, lineWidth: 2)
                    }
                    .overlay {
                        if candidate.isChecked {
                            Image(systemName: "checkmark")
                                .font(.system(size: checkmarkSize, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    // UX audit: this is the row's only deselect affordance,
                    // so it needs its own 44pt floor (BUILD_PLAN §6.5), not
                    // just a share of the row's wider tap band — grows only
                    // the invisible tappable area around the checkbox (same
                    // "frame after the visual size" recipe as `TripView
                    // .pasteImportPill`); the visible box stays pinned to
                    // `checkboxSide`.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // This checkbox had no accessible label at all — VoiceOver read
            // either nothing or the checkmark glyph's own SF Symbol name,
            // depending on state. Mirrors `PackingListView`'s
            // reference-standard checkbox: label + checked state as a
            // value, not baked into the label.
            .accessibilityLabel(candidate.label.isEmpty ? "Packing item" : candidate.label)
            .accessibilityValue(candidate.isChecked ? "Included" : "Excluded")
            .accessibilityAddTraits(candidate.isChecked ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 2) {
                TextField("Item", text: $candidate.label)
                    .font(Typo.body(Typo.Size.body, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    Image(systemName: candidate.groupKey.symbolName)
                        .font(.system(size: groupIconSize, weight: .bold))
                        // Decorative — the group name right next to it says
                        // the same thing.
                        .accessibilityHidden(true)
                    Text(candidate.groupKey.displayName)
                        .font(Typo.body(11, weight: .semibold))
                }
                .foregroundStyle(Palette.slate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .opacity(candidate.isChecked ? 1 : 0.55)
    }
}

#Preview {
    @Previewable @State var candidate = PackingCandidate(label: "Passports", groupKey: .documents)
    return PackingCandidateRow(candidate: $candidate)
        .padding(Spacing.xl)
        .background(Palette.paper)
}
