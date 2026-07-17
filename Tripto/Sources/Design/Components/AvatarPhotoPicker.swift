import PhotosUI
import SwiftUI

/// PhotosPicker-backed "Add/Change/Remove photo" row (P8a — profile avatar
/// photos), shared by Settings' own "Profile" section and
/// `TripProfileFormSheet` (organizer editing any trip profile). `PhotosPicker`
/// needs no Info.plist usage-description key (plan D1) — it runs the system
/// picker out-of-process and never requests photo-library permission at all.
///
/// The pipeline (P8a brief): pick -> `loadTransferable(type: Data.self)`
/// (never `Image` — that would skip straight past `ImageProcessing`'s own
/// downsample step) -> `ImageProcessing.downsampledJPEG` -> `AvatarStorage
/// .upload`. `avatarPath` only ever changes on a *successful* upload — a
/// failure leaves it untouched and reuses the host screen's own toast (P8a
/// brief: "no path write on failed upload — atomicity").
struct AvatarPhotoPicker: View {
    let initial: String
    let colorName: String
    @Binding var avatarPath: String?
    /// The ACTING/signed-in user's id (`AuthManager.userId`), never the
    /// photo's subject — see `AvatarStorage`'s own doc comment for why.
    /// `nil` (signed out) disables uploading rather than crashing on it.
    let uploaderUserId: UUID?
    /// Reuses the host screen's own toast vocabulary (P8a brief) rather than
    /// owning a second one — both call sites already have `@State private
    /// var toast: String?` + `.toastOverlay`.
    @Binding var toast: String?
    var diameter: CGFloat = 72
    /// Settings' V1 aligned-rows relayout shortens this to "Remove" for its
    /// own grouped avatar-actions row; `TripProfileFormSheet` keeps the
    /// original wording via this default.
    var removeLabel: String = "Remove photo"
    /// Settings' V1 relayout groups "Change photo"/"Remove" directly under
    /// the avatar (an `HStack`, side by side with each other) instead of the
    /// default beside-the-circle `VStack` (`TripProfileFormSheet`'s
    /// unchanged layout, one button stacked above the other).
    var actionsBelowAvatar: Bool = false

    @State private var pickerItem: PhotosPickerItem?
    @State private var isPresentingPicker = false
    @State private var isUploading = false

    /// P7e (round-2 re-audit item 2a): both call sites (`SettingsView
    /// .initials(from:)`, `TripProfileFormSheet.initials`) hand this a
    /// literal `"?"` for a still-blank display name — a brand-new profile,
    /// before its first character is typed. Rendered verbatim (the pre-fix
    /// behavior), that reads as an error glyph, not "nothing entered yet".
    /// Scoped to exactly that sentinel plus "no photo" so a real single-
    /// letter initial (or an already-uploaded photo) always renders through
    /// `AvatarPhotoCircle` as before — this only replaces the one state that
    /// actually had nothing to show.
    private var isEmptyState: Bool {
        avatarPath == nil && (initial.trimmingCharacters(in: .whitespaces).isEmpty || initial == "?")
    }

    var body: some View {
        Group {
            if actionsBelowAvatar {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    preview
                    actionsContent
                }
            } else {
                HStack(spacing: Spacing.md) {
                    preview
                    actionsContent
                    Spacer(minLength: 0)
                }
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await upload(newItem) }
        }
    }

    /// Decorative — the buttons beside/below it (and the Name field
    /// elsewhere on these forms) already say whose photo this is; same
    /// treatment the plain preview circle this row replaces already had on
    /// both call sites.
    private var preview: some View {
        ZStack {
            if isEmptyState {
                emptyAvatarPlaceholder
            } else {
                AvatarPhotoCircle(initial: initial, colorName: colorName, avatarPath: avatarPath, diameter: diameter)
            }
            if isUploading {
                Circle()
                    .fill(.black.opacity(0.35))
                    .frame(width: diameter, height: diameter)
                ProgressView()
                    .tint(.white)
            }
        }
        .accessibilityHidden(true)
    }

    /// "Change/Add photo" + (once set) "Remove" — `actionsBelowAvatar`
    /// switches only the ARRANGEMENT of these two buttons (`HStack`,
    /// Settings' V1 row) vs. the original stacked `VStack` beside the circle
    /// (`TripProfileFormSheet`); the buttons themselves are identical either
    /// way.
    @ViewBuilder
    private var actionsContent: some View {
        if actionsBelowAvatar {
            HStack(spacing: Spacing.md) {
                changePhotoButton
                if avatarPath != nil { removeButton }
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                changePhotoButton
                if avatarPath != nil { removeButton }
            }
        }
    }

    /// The system picker itself is presented via `.photosPicker(isPresented
    /// :selection:matching:)` rather than `PhotosPicker(selection:matching:)
    /// { label }` — the trigger and `pickerItem`/upload flow are otherwise
    /// byte-identical either branch below.
    ///
    /// Reviewer finding: the standard `.primaryCapsule` recipe (font/
    /// padding/44pt-floor/contentShape/background order a fix-round bug
    /// elsewhere in this codebase depended on) is real, but only for
    /// Settings' own grouped row (`actionsBelowAvatar`) — applying it to
    /// BOTH call sites visually drifted `TripProfileFormSheet`'s default
    /// path from its pre-branch look (caption 12.5 bold + `Spacing.md` vs.
    /// the standard style's body 14.5 semibold + `Spacing.xl`). The `else`
    /// branch restores that original bespoke chain byte-for-byte, same
    /// modifier order (frame -> contentShape -> background).
    ///
    /// `label` carries `.lineLimit(1)` + `.fixedSize(horizontal: true,
    /// vertical: false)` on both branches — fix round: "Change photo"
    /// wrapped to two lines inside Settings' narrower grouped-actions
    /// column; `.fixedSize` makes this Text always report its full
    /// single-line width as its ideal size (the row's sibling — the
    /// "Display name" field — is the one meant to flex, via its own
    /// `maxWidth: .infinity` in `SettingsView.profileAvatarRow`) instead of
    /// this button silently accepting a too-narrow proposal and wrapping.
    @ViewBuilder
    private var changePhotoButton: some View {
        let label = Text(avatarPath == nil ? "Add photo" : "Change photo")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        if actionsBelowAvatar {
            Button {
                isPresentingPicker = true
            } label: {
                label
            }
            .buttonStyle(PrimaryCapsuleButtonStyle())
            .disabled(isUploading)
            .photosPicker(isPresented: $isPresentingPicker, selection: $pickerItem, matching: .images)
        } else {
            Button {
                isPresentingPicker = true
            } label: {
                label
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.onAmber)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.md)
                    .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
                    .contentShape(Capsule())
                    .background(Palette.amber, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isUploading)
            .photosPicker(isPresented: $isPresentingPicker, selection: $pickerItem, matching: .images)
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            avatarPath = nil
        } label: {
            Text(removeLabel)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.rose)
                // Fix round: pairs with `changePhotoButton`'s own
                // `.fixedSize` — making ONLY that sibling refuse to shrink
                // just shifted the same "too little width proposed" problem
                // onto this Text instead (Settings' grouped-actions row
                // squeezed "Remove" down to a sliver, wrapping it one
                // letter per line). Same fix, same reasoning: always report
                // this Text's full single-line width as its ideal size.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(isUploading)
    }

    /// `isEmptyState`'s own rendering — same circle fill (`colorName`) and
    /// diameter as `AvatarPhotoCircle` so nothing jumps in size or color the
    /// moment a name or photo actually lands, just the glyph inside it.
    /// Decorative — `preview` above is already `.accessibilityHidden` (the
    /// "Add photo" button beside/below it is the one real control, and
    /// already carries that exact label).
    private var emptyAvatarPlaceholder: some View {
        Circle()
            .fill(AvatarColor.color(named: colorName))
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "camera.fill")
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private func upload(_ item: PhotosPickerItem) async {
        guard let uploaderUserId else {
            toast = "Sign in first, then try again."
            return
        }
        isUploading = true
        defer {
            isUploading = false
            pickerItem = nil // lets re-picking the same asset re-trigger `.onChange`
        }
        do {
            // Never `type: Image.self` — that would decode straight to a
            // SwiftUI `Image` with no `Data` left to hand `ImageProcessing`
            // (P8a brief: "loadTransferable(type: Data.self) — never Image").
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                toast = "Couldn\u{2019}t read that photo. Try another."
                return
            }
            let jpeg = try await ImageProcessing.downsampledJPEG(rawData)
            let path = try await AvatarStorage.upload(jpeg, for: uploaderUserId)
            avatarPath = path
        } catch {
            toast = PhotoUploadFeedback.message(for: error)
        }
    }
}

#Preview {
    @Previewable @State var pathA: String?
    @Previewable @State var pathB: String?
    @Previewable @State var pathC: String?
    @Previewable @State var toast: String?
    return VStack(alignment: .leading, spacing: Spacing.xl) {
        AvatarPhotoPicker(initial: "N", colorName: "amber", avatarPath: $pathA, uploaderUserId: UUID(), toast: $toast)
        AvatarPhotoPicker(initial: "P", colorName: "moss", avatarPath: $pathB, uploaderUserId: nil, toast: $toast)
        // P7e (round-2 re-audit item 2a): a brand-new profile, name not yet
        // typed — the "?" glyph this replaces, previewed alongside the
        // normal-initial rows above for an easy side-by-side comparison.
        AvatarPhotoPicker(initial: "?", colorName: "sky", avatarPath: $pathC, uploaderUserId: UUID(), toast: $toast)
        // Settings' V1 aligned-rows layout: actions grouped below the
        // avatar, shortened "Remove" label.
        AvatarPhotoPicker(
            initial: "N", colorName: "amber", avatarPath: $pathA, uploaderUserId: UUID(), toast: $toast,
            diameter: 56, removeLabel: "Remove", actionsBelowAvatar: true
        )
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
    .toastOverlay($toast)
}
