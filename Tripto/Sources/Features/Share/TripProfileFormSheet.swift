import SwiftUI

/// Add/edit sheet for a non-app `TripProfile` (BUILD_PLAN.md §3.3/§5.3, this
/// milestone's brief §2) — the kids/grandparents `ShareTripView` renders as
/// "Assignable · no account" rows. Display name + an avatar-color swatch
/// picker, nothing else: these rows have no email, no role, no invite —
/// just enough identity to be assignable on items and packing tasks.
///
/// A plain callback-driven form (`onSave`/`onDelete`), matching
/// `PackingItemFormSheet`'s "dumb form, caller owns the SwiftData/sync
/// write" shape — this sheet never touches `modelContext`/`SyncEngine`
/// itself.
struct TripProfileFormSheet: View {
    enum Mode {
        case add
        case edit(TripProfile)
    }

    let mode: Mode
    let onSave: (_ displayName: String, _ avatarColor: String) -> Void
    /// `nil` when adding (there's nothing to delete yet); non-nil in edit
    /// mode. Callers gate whether edit mode is even reachable to organizers
    /// only (`trip_profiles_update`/`_delete` RLS, confirmed live: organizer
    /// only) — this sheet doesn't re-derive that itself.
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var avatarColor: String
    @State private var isPresentingDeleteConfirm = false

    /// The four named colors `AvatarColor.color(named:)` actually resolves
    /// (anything else falls back to slate) — matching the palette already
    /// seeded server-side for `profiles`/`trip_profiles.avatar_color`.
    static let swatches = ["amber", "moss", "sky", "plum"]

    init(mode: Mode, onSave: @escaping (String, String) -> Void, onDelete: (() -> Void)? = nil) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .add:
            _displayName = State(initialValue: "")
            _avatarColor = State(initialValue: Self.swatches.randomElement() ?? "sky")
        case .edit(let profile):
            _displayName = State(initialValue: profile.displayName)
            _avatarColor = State(initialValue: profile.avatarColor)
        }
    }

    private var isEditing: Bool { if case .edit = mode { true } else { false } }
    private var isValid: Bool { !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var initials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : trimmed.prefix(1).uppercased()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.mist).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        HStack {
                            Spacer(minLength: 0)
                            Circle()
                                .fill(AvatarColor.color(named: avatarColor))
                                .frame(width: 64, height: 64)
                                .overlay {
                                    Text(initials)
                                        .font(Typo.display(22))
                                        .foregroundStyle(.white)
                                }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, Spacing.sm)

                        FormTextField(label: "Name", text: $displayName, placeholder: "Meera, Grandma\u{2026}")

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Color")
                                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                                .foregroundStyle(Palette.slate)
                            HStack(spacing: Spacing.md) {
                                ForEach(Self.swatches, id: \.self) { swatch in
                                    swatchButton(swatch)
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        Text("They\u{2019}ll show up as assignable on plans and packing \u{2014} no account or invite needed.")
                            .font(Typo.body(10.5))
                            .foregroundStyle(Palette.slate)

                        saveButton

                        if isEditing, onDelete != nil {
                            Button(role: .destructive) {
                                isPresentingDeleteConfirm = true
                            } label: {
                                Text("Remove from trip")
                                    .font(Typo.body(weight: .semibold))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, Spacing.md)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .confirmationDialog(
            "Remove \(displayName.isEmpty ? "this person" : displayName) from the trip?",
            isPresented: $isPresentingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They\u{2019}ll no longer be assignable on plans or packing tasks.")
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.slate)
            Spacer()
            Text(isEditing ? "Edit profile" : "Add someone without the app")
                .font(Typo.body(weight: .bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            Text("Cancel").font(Typo.body(weight: .semibold)).opacity(0) // balances the leading button
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    private func swatchButton(_ swatch: String) -> some View {
        let isOn = avatarColor == swatch
        return Button {
            avatarColor = swatch
        } label: {
            Circle()
                .fill(AvatarColor.color(named: swatch))
                .frame(width: 36, height: 36)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle().stroke(isOn ? Palette.ink.opacity(0.25) : Color.clear, lineWidth: 2)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.capitalized)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var saveButton: some View {
        Button {
            onSave(displayName.trimmingCharacters(in: .whitespacesAndNewlines), avatarColor)
            dismiss()
        } label: {
            Text(isEditing ? "Save changes" : "Add to trip")
                .font(Typo.body(weight: .semibold))
                .frame(maxWidth: .infinity)
                .foregroundStyle(.white)
                .padding(.vertical, Spacing.md)
                .background(Palette.amber, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isValid)
        .opacity(isValid ? 1 : 0.5)
    }
}
