import PhotosUI
import QuickLookThumbnailing
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Thumbnail strip + add/delete for an item's `ItemAttachment`s
/// (`docs/PRODUCT_PLAN.md` §2.1), living in `BookingDetailView` right after
/// the action row. Reads its own `@Query`, filtered by `item.id` — the same
/// "receive an id, query the rest" shape `BookingDetailView` itself already
/// uses for `items` — so nothing needs threading down from the host screen
/// but the item and the acting member's own role/id.
struct AttachmentStrip: View {
    let item: ItineraryItem
    let myRole: TripRole?
    let myUserId: UUID?
    @Binding var toast: String?

    @Query private var attachments: [ItemAttachment]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine

    @State private var isPresentingAddDialog = false
    @State private var isPresentingPhotosPicker = false
    @State private var isPresentingFileImporter = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var loadingAttachmentId: UUID?
    @State private var previewTarget: AttachmentPreviewItem?
    @State private var attachmentPendingDelete: ItemAttachment?
    /// UX-13: toggled, never read — `.sensoryFeedback` trigger, same
    /// convention as `BookingDetailView.didDeleteItem`.
    @State private var didDeleteAttachment = false

    init(item: ItineraryItem, myRole: TripRole?, myUserId: UUID?, toast: Binding<String?>) {
        self.item = item
        self.myRole = myRole
        self.myUserId = myUserId
        self._toast = toast
        let itemId = item.id
        _attachments = Query(
            filter: #Predicate<ItemAttachment> { $0.itemId == itemId }, sort: \ItemAttachment.createdAt
        )
    }

    /// Same rule as adding an itinerary item itself (ACCEPTANCE.md "(b)":
    /// organizer or companion, not viewer) — attaching a file to an item is
    /// the same weight of action as editing it.
    private var canAdd: Bool { ItemPermissions.canAdd(role: myRole) }

    /// Mirrors the server RLS delete rule (C1: `USING created_by =
    /// auth.uid() OR trip_role(trip_id) = 'organizer'`) — convenience only,
    /// never the real boundary (CLAUDE.md). `createdBy == nil` (the
    /// uploader's account was since deleted) can only ever be deleted by an
    /// organizer, mirroring `ItemPermissions.canEdit`'s identical treatment
    /// of a nil `ItineraryItem.createdBy`.
    private func canDelete(_ attachment: ItemAttachment) -> Bool {
        guard let createdBy = attachment.createdBy else { return myRole == .organizer }
        return myRole == .organizer || createdBy == myUserId
    }

    private var atCap: Bool { attachments.count >= AttachmentService.maxPerItem }

    private var service: AttachmentService {
        AttachmentService(modelContext: modelContext, syncEngine: syncEngine, uploaderUserId: myUserId)
    }

    var body: some View {
        if !attachments.isEmpty || canAdd {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("ATTACHMENTS")
                    .font(Typo.body(12, weight: .bold))
                    .foregroundStyle(Palette.slate)
                    .tracking(0.5)

                // UX-8 (BUILD_PLAN.md §6.6: "empty screens are invitations,
                // not mood") — the empty-but-addable state used to render
                // just the header + Add pill with no explanation, unlike
                // this screen's own TRIP NOTE sibling (`notesBlock`), which
                // always names what to add.
                if attachments.isEmpty && canAdd {
                    Text("Add a boarding pass, voucher, or ticket \u{2014} anyone on the trip can see it.")
                        .font(Typo.body())
                        .foregroundStyle(Palette.slate)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.md) {
                        ForEach(attachments) { attachment in
                            thumbnailButton(for: attachment)
                        }
                        if canAdd {
                            addButton
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                }
            }
            .confirmationDialog("Add attachment", isPresented: $isPresentingAddDialog, titleVisibility: .visible) {
                Button("Photo") { isPresentingPhotosPicker = true }
                Button("PDF file") { isPresentingFileImporter = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $isPresentingPhotosPicker, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await attachPhoto(newItem) }
            }
            .fileImporter(isPresented: $isPresentingFileImporter, allowedContentTypes: [.pdf]) { result in
                handleFileImport(result)
            }
            .sheet(item: $previewTarget) { target in
                // No .ignoresSafeArea(): the wrap now carries its own nav
                // bar (Done button) which must sit inside the sheet's safe
                // area — see QuickLookPreview's doc comment.
                QuickLookPreview(item: target)
            }
            .confirmationDialog(
                "Delete this attachment?",
                isPresented: Binding(
                    get: { attachmentPendingDelete != nil },
                    set: { isPresented in if !isPresented { attachmentPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let attachmentPendingDelete { delete(attachmentPendingDelete) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let attachmentPendingDelete {
                    Text("This removes \u{201C}\(attachmentPendingDelete.fileName)\u{201D} for everyone on the trip.")
                }
            }
            // UX-13: matches `BookingDetailView`'s own warning haptic on
            // its item-delete confirm (`didDeleteItem`) — same vocabulary
            // (`Design/Motion.swift`), same "destructive confirm" tier.
            .sensoryFeedback(Haptics.warning, trigger: didDeleteAttachment)
        }
    }

    // MARK: - Thumbnails

    private func thumbnailButton(for attachment: ItemAttachment) -> some View {
        Button {
            openAttachment(attachment)
        } label: {
            ZStack {
                AttachmentThumbnail(attachment: attachment)
                if loadingAttachmentId == attachment.id {
                    RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous)
                        .fill(.black.opacity(0.35))
                        .frame(width: AttachmentThumbnail.diameter, height: AttachmentThumbnail.diameter)
                    ProgressView().tint(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel(for: attachment))
        .accessibilityHint(Text("Opens a preview"))
        .contextMenu {
            if canDelete(attachment) {
                Button(role: .destructive) {
                    attachmentPendingDelete = attachment
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // UX-3: the contextMenu above has no visible affordance at all
            // (long-press-only); this adds an always-visible one without
            // removing that menu.
            if canDelete(attachment) {
                deleteBadge(for: attachment)
            }
        }
    }

    /// Deliberately smaller than this screen's usual 44pt tap-target floor:
    /// at 64pt thumbnails spaced `Spacing.md` (12pt) apart, a full 44pt
    /// free-floating corner target would overlap the next thumbnail's own
    /// tap area. Sized like the platform's own dense-list remove badges
    /// (Photos multi-select, Safari tab-close chips) — `.padding`+
    /// `.contentShape` still widens the tap area well past the visible
    /// glyph. VoiceOver is unaffected by the smaller visual/tap size (focus
    /// + double-tap-anywhere, not precision pointing), and the fully-sized
    /// `contextMenu` row above remains the robust affordance either way.
    private func deleteBadge(for attachment: ItemAttachment) -> some View {
        Button {
            attachmentPendingDelete = attachment
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Palette.rose, in: Circle())
                .overlay { Circle().stroke(Palette.paper, lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
        .padding(6)
        .contentShape(Circle())
        .offset(x: 8, y: -8)
        .accessibilityLabel("Delete \(attachment.fileName)")
    }

    /// "Attachment, boarding pass dot pdf" — VoiceOver reads a literal "."
    /// as silence, so the extension would otherwise vanish from the spoken
    /// label entirely.
    private func spokenLabel(for attachment: ItemAttachment) -> String {
        "Attachment, " + attachment.fileName.replacingOccurrences(of: ".", with: " dot ")
    }

    private var addButton: some View {
        Button {
            isPresentingAddDialog = true
        } label: {
            HStack(spacing: Spacing.xs) {
                if isUploading {
                    ProgressView().tint(Palette.onAmber)
                } else if !atCap {
                    Image(systemName: "plus")
                }
                // UX-6/UX-7: the cap is pre-surfaced as a short "10/10"
                // caption right on the pill (matching PasteImportSheet's
                // own busy-label precedent, "Import" -> "Importing…")
                // rather than only failing after a tap.
                Text(addButtonLabel)
            }
        }
        .buttonStyle(.primaryCapsule)
        .disabled(isUploading || atCap)
        .accessibilityLabel(atCap ? "Add attachment, limit reached" : "Add attachment")
    }

    private var addButtonLabel: String {
        if atCap { return "\(AttachmentService.maxPerItem)/\(AttachmentService.maxPerItem)" }
        return isUploading ? "Adding\u{2026}" : "Add"
    }

    // MARK: - Add flow

    private func attachPhoto(_ pickerItem: PhotosPickerItem) async {
        defer { self.pickerItem = nil } // lets re-picking the same asset re-trigger `.onChange`
        // Never `type: Image.self` — that would decode straight to a
        // SwiftUI `Image` with no `Data` left to hand `ImageProcessing`
        // (`AvatarPhotoPicker`'s established rule).
        guard let data = try? await pickerItem.loadTransferable(type: Data.self) else {
            toast = "Couldn\u{2019}t read that photo. Try another."
            return
        }
        await attach(data: data, contentType: .jpeg, fileName: "Photo \(attachments.count + 1).jpg")
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            toast = friendlyMessage(for: error)
        case .success(let url):
            // `.fileImporter` hands back a security-scoped URL — must
            // bracket the read (Apple's documented contract for picked
            // files outside the app's own sandbox; `SettingsView`'s archive
            // importer establishes the same pattern).
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            // Reject an oversized file via its size attribute BEFORE
            // reading the whole thing into memory.
            if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                fileSize > AttachmentService.maxBytes {
                toast = friendlyMessage(for: AttachmentServiceError.fileTooLarge)
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                toast = "Couldn\u{2019}t read that file. Try another."
                return
            }
            Task { await attach(data: data, contentType: .pdf, fileName: url.lastPathComponent) }
        }
    }

    private func attach(data: Data, contentType: AttachmentContentType, fileName: String) async {
        isUploading = true
        defer { isUploading = false }
        do {
            try await service.attach(data: data, contentType: contentType, fileName: fileName, to: item)
        } catch {
            toast = friendlyMessage(for: error)
        }
    }

    // MARK: - Preview / delete

    private func openAttachment(_ attachment: ItemAttachment) {
        if let cached = AttachmentStore.cachedFileURL(id: attachment.id, contentType: attachment.contentType) {
            previewTarget = AttachmentPreviewItem(id: attachment.id, url: cached, title: attachment.fileName)
            return
        }
        guard loadingAttachmentId != attachment.id else { return }
        loadingAttachmentId = attachment.id
        Task {
            defer { loadingAttachmentId = nil }
            do {
                let url = try await service.localFileURL(for: attachment)
                previewTarget = AttachmentPreviewItem(id: attachment.id, url: url, title: attachment.fileName)
            } catch {
                toast = "Couldn\u{2019}t load that attachment. Check your connection and try again."
            }
        }
    }

    private func delete(_ attachment: ItemAttachment) {
        // UX-13: fires the moment the destructive confirm is tapped, same
        // "instant feedback on confirm, not on eventual async completion"
        // timing as `BookingDetailView.deleteItem`'s own `didDeleteItem`.
        didDeleteAttachment.toggle()
        Task {
            do {
                try await service.delete(attachment)
            } catch {
                toast = "Couldn\u{2019}t delete that attachment. Try again."
            }
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        switch error {
        case AttachmentServiceError.tooManyAttachments:
            return "You can attach up to \(AttachmentService.maxPerItem) files to this item."
        case AttachmentServiceError.fileTooLarge:
            return "That file is over \(AttachmentService.maxBytes / 1_024 / 1_024)\u{00A0}MB. Try a smaller one."
        case AttachmentServiceError.notSignedIn:
            return "Sign in first, then try again."
        case is ImageProcessingError:
            return "Couldn\u{2019}t prepare that photo. Try a different one."
        default:
            return "Couldn\u{2019}t add that attachment. Check your connection and try again."
        }
    }
}

/// Images: a local downsampled thumbnail from the cached file. PDFs: a
/// `QLThumbnailGenerator` render of the first page, same generator either
/// way — one code path instead of forking image/PDF thumbnailing. Not yet
/// cached (offline, or simply not prefetched) or generation failed: a
/// doc/photo glyph fallback, never blank (PRODUCT_PLAN.md §2.1's offline
/// requirement).
private struct AttachmentThumbnail: View {
    let attachment: ItemAttachment
    static let diameter: CGFloat = 64

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous)
                .fill(Palette.mist)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.diameter, height: Self.diameter)
                    .transition(.opacity)
            } else {
                Image(systemName: attachment.contentType == .pdf ? "doc.richtext" : "photo")
                    .font(.system(size: Self.diameter * 0.32, weight: .medium))
                    .foregroundStyle(Palette.slate)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous).stroke(Palette.mist, lineWidth: 1)
        }
        // Decorative — the button wrapping this (`thumbnailButton`) already
        // carries the real spoken label.
        .accessibilityHidden(true)
        // ponytail: only checks the cache once per attachment identity, so a
        // thumbnail that upgrades from icon-fallback to a real preview via a
        // lazy `openAttachment` download stays on the fallback glyph for the
        // rest of THIS screen visit — it refreshes on the next time this
        // trip/screen is opened (a fresh `.task` run). Not worth extra state
        // to track "just downloaded" for a cosmetic, session-scoped gap.
        .task(id: attachment.id) {
            guard let url = AttachmentStore.cachedFileURL(id: attachment.id, contentType: attachment.contentType)
            else { return }
            let thumbnail = await AttachmentThumbnailGenerator.thumbnail(
                for: url, diameter: Self.diameter, scale: displayScale
            )
            withAnimation(Motion.m(Motion.fade, reduceMotion: reduceMotion)) {
                image = thumbnail
            }
        }
    }
}

private enum AttachmentThumbnailGenerator {
    @MainActor
    static func thumbnail(for url: URL, diameter: CGFloat, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: diameter, height: diameter), scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                continuation.resume(returning: thumbnail?.uiImage)
            }
        }
    }
}
