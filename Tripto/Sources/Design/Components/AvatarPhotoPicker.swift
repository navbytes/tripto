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

    @State private var pickerItem: PhotosPickerItem?
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
        HStack(spacing: Spacing.md) {
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
            // Decorative — the buttons beside it (and the Name field
            // elsewhere on these forms) already say whose photo this is;
            // same treatment the plain preview circle this row replaces
            // already had on both call sites.
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Fix-round (client-reported bug): the visual pill rendered
                // bare-text small (~20pt) despite a correct 44pt hit band —
                // `.background` used to sit BEFORE `.frame(minHeight:)`, so
                // the painted capsule sized itself to the unpadded text,
                // floating small inside the invisible 44pt frame around it.
                // `.frame(minHeight:)` before `.contentShape` (still) is what
                // makes the whole frame tappable; `.background` LAST is what
                // makes the capsule actually fill it — same order as every
                // other 44pt pill CTA already shipped in this codebase
                // (`HomeView`, `BookingsTabView`, `PackingListView`,
                // `ItineraryTabView`, `TripView`, `BookingDetailView`).
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text(avatarPath == nil ? "Add photo" : "Change photo")
                        .font(Typo.body(Typo.Size.caption, weight: .bold))
                        .foregroundStyle(Palette.onAmber)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.md)
                        .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
                        .contentShape(Capsule())
                        .background(Palette.amber, in: Capsule())
                }
                .disabled(isUploading)

                if avatarPath != nil {
                    Button(role: .destructive) {
                        avatarPath = nil
                    } label: {
                        Text("Remove photo")
                            .font(Typo.body(Typo.Size.caption, weight: .semibold))
                            .foregroundStyle(Palette.rose)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(isUploading)
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await upload(newItem) }
        }
    }

    /// `isEmptyState`'s own rendering — same circle fill (`colorName`) and
    /// diameter as `AvatarPhotoCircle` so nothing jumps in size or color the
    /// moment a name or photo actually lands, just the glyph inside it.
    /// Decorative — the whole `ZStack` above is already `.accessibilityHidden`
    /// (the "Add photo" `PhotosPicker` button beside it is the one real
    /// control, and already carries that exact label).
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
            toast = "Couldn\u{2019}t upload that photo. Try again."
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
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
    .toastOverlay($toast)
}
