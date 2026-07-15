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
    /// P8a: widened to carry `avatarPath` alongside the existing pair —
    /// still just values, the caller (`ShareTripView`) still owns every
    /// SwiftData/sync write, this sheet still never touches
    /// `modelContext`/`SyncEngine` itself.
    let onSave: (_ displayName: String, _ avatarColor: String, _ avatarPath: String?) -> Void
    /// `nil` when adding (there's nothing to delete yet); non-nil in edit
    /// mode. Callers gate whether edit mode is even reachable to organizers
    /// only (`trip_profiles_update`/`_delete` RLS, confirmed live: organizer
    /// only) — this sheet doesn't re-derive that itself.
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// P8a: the only new environment dependency this sheet needs — read-only,
    /// same lightweight ambient-environment reference every other form sheet
    /// in the app already grabs (`SettingsView`, `TripView`, ...), not the
    /// "SwiftData/sync write" this sheet's own doc comment is about. Needed
    /// only to know whose owner-folder an uploaded photo goes under
    /// (`AvatarStorage`'s own doc comment) — never to gate whether this
    /// sheet itself is reachable.
    @Environment(AuthManager.self) private var authManager
    @State private var displayName: String
    @State private var avatarColor: String
    /// P8a: `TripProfile` (unlike `SettingsView`'s async-pulled `Profile`) is
    /// already in hand synchronously in edit mode (`mode.edit(profile)`), so
    /// this seeds directly here — no "seeded yet?" race/flag needed the way
    /// `SettingsView.hasSeededAvatarPath` is for its own async-arriving
    /// profile.
    @State private var avatarPath: String?
    @State private var toast: String?
    @State private var isPresentingDeleteConfirm = false
    /// UX audit finding 4: gates the "Discard changes?" confirmation on
    /// Cancel/swipe-dismiss — same guard `TripFormView`/`AddItemSheet`
    /// already apply, extended here and to `PackingItemFormSheet`, the two
    /// form sheets that had been skipping it.
    @State private var showDiscardConfirm = false

    /// The name/color/photo this sheet opened with, so `hasChanges` can tell
    /// an untouched form from a dirty one — same role as
    /// `TripFormView.initialValues`. In add mode the color starts at
    /// whatever random swatch the sheet opened with (below), not a fixed
    /// default, so accepting that random pick isn't itself "dirty."
    private let initialDisplayName: String
    private let initialAvatarColor: String
    private let initialAvatarPath: String?

    init(
        mode: Mode, onSave: @escaping (String, String, String?) -> Void, onDelete: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .add:
            let randomColor = AvatarColorPicker.swatches.randomElement() ?? "sky"
            _displayName = State(initialValue: "")
            _avatarColor = State(initialValue: randomColor)
            _avatarPath = State(initialValue: nil)
            initialDisplayName = ""
            initialAvatarColor = randomColor
            initialAvatarPath = nil
        case .edit(let profile):
            _displayName = State(initialValue: profile.displayName)
            _avatarColor = State(initialValue: profile.avatarColor)
            _avatarPath = State(initialValue: profile.avatarPath)
            initialDisplayName = profile.displayName
            initialAvatarColor = profile.avatarColor
            initialAvatarPath = profile.avatarPath
        }
    }

    private var isEditing: Bool { if case .edit = mode { true } else { false } }
    private var isValid: Bool { !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var initials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : trimmed.prefix(1).uppercased()
    }

    /// UX audit finding 4: whether either field has moved from what the
    /// sheet opened with. P8a: widened for `avatarPath` — a picked-then-
    /// uploaded-but-not-yet-saved photo is discardable exactly like a typed-
    /// but-not-saved name (the uploaded object itself is simply left as an
    /// orphan, same v1 policy `AvatarStorage`'s doc comment already accepts
    /// for a replaced photo).
    private var hasChanges: Bool {
        displayName != initialDisplayName || avatarColor != initialAvatarColor || avatarPath != initialAvatarPath
    }

    private func cancelTapped() {
        if hasChanges {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.mist).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        // P8a: replaces the old decorative-only, centered
                        // preview circle — same position (above Name), now
                        // the one real photo-management row (plan D6:
                        // "photo row above the existing AvatarColorPicker").
                        // Left-aligned (its own trailing `Spacer` fills the
                        // rest of the row for the Change/Remove buttons),
                        // same layout `SettingsView`'s identical row uses,
                        // rather than centered like the old plain circle —
                        // there are real interactive buttons attached now,
                        // not just a static preview. The uploader is always
                        // the ACTING organizer editing this profile, not this
                        // profile's own (possibly absent, for a no-account
                        // kid/grandparent) `linkedUserId` — see
                        // `AvatarStorage`'s doc comment.
                        AvatarPhotoPicker(
                            initial: initials, colorName: avatarColor, avatarPath: $avatarPath,
                            uploaderUserId: authManager.userId, toast: $toast, diameter: 64
                        )
                        .padding(.top, Spacing.sm)

                        FormTextField(label: "Name", text: $displayName, placeholder: "Meera, Grandma\u{2026}")

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Color")
                                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                                .foregroundStyle(Palette.slate)
                            // UX audit finding 9: shared `AvatarColorPicker`
                            // (extracted from this sheet's original swatch
                            // row) — Settings' own profile section now
                            // renders the identical control.
                            HStack(spacing: 0) {
                                AvatarColorPicker(selection: $avatarColor)
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
                                    .foregroundStyle(Palette.rose)
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
        // P8a: reuses the app's one toast vocabulary for an upload failure
        // (brief: "handle upload failure with the existing Toast
        // vocabulary") — this sheet's own, same as every other screen that
        // toasts (`Toast.swift`'s doc comment: "not a global center").
        .toastOverlay($toast)
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
        // UX audit finding 4: same guard `TripFormView`/`AddItemSheet` use —
        // a stray swipe-down while naming a non-app profile used to
        // silently lose the input.
        .background(
            SheetDismissAttemptObserver {
                if hasChanges { showDiscardConfirm = true }
            }
        )
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel", action: cancelTapped)
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.slate)
            Spacer()
            Text(isEditing ? "Edit profile" : "Add someone without the app")
                .font(Typo.body(weight: .bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            // Balances the leading button. `.opacity(0)` only hides it
            // visually — `.accessibilityHidden` keeps VoiceOver from
            // landing on a phantom "Cancel" (same fix as `SheetHeader`).
            Text("Cancel").font(Typo.body(weight: .semibold)).opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    private var saveButton: some View {
        Button {
            onSave(displayName.trimmingCharacters(in: .whitespacesAndNewlines), avatarColor, avatarPath)
            dismiss()
        } label: {
            Text(isEditing ? "Save changes" : "Add to trip")
                .font(Typo.body(weight: .semibold))
                .frame(maxWidth: .infinity)
                .foregroundStyle(isValid ? Palette.onAmber : Palette.slate)
                .padding(.vertical, Spacing.md)
                .background(
                    isValid ? Palette.amber : Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isValid)
    }
}
