import Foundation
import NukeUI
import Supabase
import SwiftUI

/// P8c (Pexels stock-photo cover search; `.claude/company/ux-redesign/
/// handoffs/P8-images-plan.md`, DECISIONS.md 2026-07-16): search sheet in
/// front of the authenticated `search-covers` edge function \u{2014} the
/// Pexels key never enters this repo (CLAUDE.md "Security model"), only the
/// backend's secrets. Reached from `TripFormView`'s cover section, "Search
/// photos" beside "Choose a photo" \u{2014} both are independent entry
/// points into the same draft `coverImagePath`, this one also supplying the
/// credit pair Pexels' API terms require.
///
/// Verified terms (DECISIONS.md 2026-07-16): attribution only has to live in
/// the SEARCH FLOW, not the final rendered cover \u{2014} this sheet is the
/// whole obligation, in two places: a persistent, always-visible "Photos
/// provided by Pexels" header link, and each result's own "Photo by {name}"
/// caption. `TripFormView`'s own credit render slot (once this sheet hands
/// back a credit) is a bonus surfacing later, in trip info \u{2014} not the
/// contractual surface.
///
/// Pick pipeline (plan D2), once a result is tapped: download the chosen
/// size's bytes (`processAndUpload` below) -> `ImageProcessing
/// .downsampledJPEG` at the SAME ~1600px cover bound `TripFormView
/// .uploadCoverPhoto`'s own PhotosPicker path uses (a Pexels photo goes
/// through the identical re-encode, so nothing downstream needs to know a
/// cover's origin) -> `CoverStorage.upload` -> hand the caller the new path
/// AND credit pair together (`onPick`), atomically \u{2014} same "nothing
/// writes until a fully successful pipeline" contract `CoverStorage.upload`'s
/// own doc comment describes.
struct CoverSearchSheet: View {
    /// The ACTING/signed-in user (`AuthManager.userId`), never the trip's
    /// \u{2014} see `AvatarStorage`'s doc comment for why. `nil` (signed
    /// out) disables picking rather than crashing on it, same as
    /// `AvatarPhotoPicker`.
    let uploaderUserId: UUID?
    /// Reports the new cover path and its Pexels credit pair back to
    /// `TripFormView`'s own draft state, together \u{2014} this sheet never
    /// writes anything itself (P8b's "nothing persists before Save"
    /// semantics carry over unchanged).
    let onPick: (_ path: String, _ creditName: String, _ creditUrl: String) -> Void
    /// Injectable for `TriptoTests` (hermetic, no network \u{2014}
    /// CLAUDE.md), mirroring `CoverStorage.upload`'s own `via:` seam.
    var searchProvider: CoverSearchProviding = SupabaseCoverSearchProvider()
    var downloader: CoverPhotoDownloading = URLSessionCoverPhotoDownloader()

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var state: SearchState = .idle
    @State private var photos: [CoverSearchResponse.Photo] = []
    @State private var currentPage = 1
    @State private var hasNextPage = false
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    /// Non-nil while that one result's own download/process/upload is in
    /// flight \u{2014} disables every cell (not just the tapped one) so a
    /// second tap can't start a race against the first (mirrors
    /// `TripFormView.isUploadingCoverPhoto`'s single-flight guard).
    @State private var pickingPhotoId: Int?
    @State private var toast: String?
    @FocusState private var searchFocused: Bool

    /// Grid reflow for Dynamic Type (CONTRACTS: "grid reflows"): a bigger
    /// scaled minimum naturally drops `.adaptive`'s column count at larger
    /// accessibility sizes, rather than shrinking cells to fit a fixed count.
    @ScaledMetric(relativeTo: .body) private var gridCellMinWidth: CGFloat = 108

    private enum SearchState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(title: "Search photos", onCancel: { dismiss() })
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    FormTextField(
                        label: "Search", text: $query, placeholder: "mountains, beaches, cities\u{2026}",
                        autocapitalization: .never, focusBinding: $searchFocused, focusValue: true
                    )
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    pexelsHeaderLink
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.lg)
                content
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .toastOverlay($toast)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            searchFocused = true
        }
        // Debounce (brief: "server rate limit is the backstop, don't hammer
        // it"): `.task(id:)` auto-cancels the previous attempt and restarts
        // on every keystroke, same idiom `Toast.swift`'s own `.task(id:
        // message)` already uses in this codebase \u{2014} no Combine/Timer
        // dependency needed.
        .task(id: query) {
            guard Self.shouldSearch(query: query) else {
                state = .idle
                photos = []
                return
            }
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
        // Finding-4-style rule (`TripFormView.saveError`'s own convention):
        // only error-toned state gets an active announcement \u{2014} the
        // idle/empty advisory copy is already visible the moment it renders.
        .onChange(of: state) { _, newValue in
            if case .failed(let message) = newValue {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    // MARK: - Header

    /// Pexels API requirement (verified DECISIONS.md 2026-07-16): a
    /// prominent, always-visible link to Pexels \u{2014} not buried at the
    /// bottom. Same external-link recipe as `PrivacySummaryView`'s "Read the
    /// full privacy policy" (`Palette.amberInk`, already measured ~5.0:1 on
    /// `Palette.paper` in light mode / ~7.7:1 in dark per that token's own
    /// doc comment, plus an `arrow.up.forward.square` glyph inheriting the
    /// same font so it scales with Dynamic Type) \u{2014} duplicated rather
    /// than extracted into a shared component for two call sites (see
    /// `TripFormView.coverPhotoCreditLine` for the other one).
    private var pexelsHeaderLink: some View {
        Link(destination: Self.pexelsHomeURL) {
            HStack(spacing: Spacing.xs) {
                Text("Photos provided by Pexels")
                Image(systemName: "arrow.up.forward.square")
                    .accessibilityHidden(true)
            }
            .font(Typo.body(Typo.Size.caption, weight: .semibold))
            .foregroundStyle(Palette.amberInk)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            statusMessage(icon: "photo.on.rectangle.angled", text: Self.idlePromptText)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: Spacing.md) {
                statusMessage(icon: "exclamationmark.circle", text: message)
                secondaryButton("Try again") { Task { await runSearch() } }
                    .frame(maxWidth: 220)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where photos.isEmpty:
            statusMessage(
                icon: "photo.on.rectangle.angled",
                text: "No photos found for \u{201C}\(trimmedQuery)\u{201D}. Try a different search."
            )
        case .loaded:
            resultsGrid
        }
    }

    private func statusMessage(icon: String, text: String) -> some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Palette.slate)
                .accessibilityHidden(true)
            Text(text)
                .multilineTextAlignment(.center)
                .helperTextStyle()
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridCellMinWidth), spacing: Spacing.sm)], spacing: Spacing.sm) {
                ForEach(photos) { photo in
                    resultCell(photo)
                }
            }
            loadMoreFooter
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Deliberately heavier scrim (up to 70% black) than the app's own
    /// `CoverGradient.textScrim` (45% max): that gradient's exact stops were
    /// measured against the app's 3 KNOWN curated gradients (`PaletteExtras
    /// .swift`'s own doc comment) \u{2014} these are arbitrary third-party
    /// search results, so there's no fixed backdrop to pre-compute a ratio
    /// against. ponytail: can't prove AA for an unknown photographic
    /// backdrop the way a fixed-palette gradient can; erring stronger here
    /// is the honest substitute, not a computed guarantee.
    private static let resultCaptionScrim = LinearGradient(
        stops: [
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.72), location: 1.0)
        ],
        startPoint: .top, endPoint: .bottom
    )

    private func resultCell(_ photo: CoverSearchResponse.Photo) -> some View {
        Button {
            Task { await pick(photo) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Palette.mist
                // `AppImagePipeline.configured` swaps in the DataCache-backed
                // pipeline before the first photo this sheet ever loads,
                // same inline gate `CoverImage.body` already uses.
                if AppImagePipeline.configured, let url = URL(string: photo.src.medium) {
                    LazyImage(url: url) { imageState in
                        if let image = imageState.image {
                            image.resizable().scaledToFill()
                        }
                        // `.empty`/`.failure` render nothing \u{2014} the
                        // `Palette.mist` tile underneath already shows
                        // through, same contract as `CoverImage`.
                    }
                }
                Self.resultCaptionScrim
                Text("Photo by \(photo.photographerName)")
                    .font(Typo.body(Typo.Size.helper, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(Spacing.xs)
                if pickingPhotoId == photo.id {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pickingPhotoId != nil)
        // Results announce photographer (brief) \u{2014} one combined
        // VoiceOver stop rather than the caption/glyph reading separately.
        .accessibilityLabel("\(photo.accessibleDescription), by \(photo.photographerName)")
        .accessibilityHint("Use this photo as your trip cover")
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if isLoadingMore {
            ProgressView()
                .padding(.vertical, Spacing.lg)
                .frame(maxWidth: .infinity)
        } else if let loadMoreError {
            VStack(spacing: Spacing.sm) {
                Text(loadMoreError).helperTextStyle().multilineTextAlignment(.center)
                secondaryButton("Try again") { Task { await loadMore() } }
                    .frame(maxWidth: 220)
            }
            .padding(.vertical, Spacing.md)
            .frame(maxWidth: .infinity)
        } else if hasNextPage {
            secondaryButton("Show more photos") { Task { await loadMore() } }
                .padding(.vertical, Spacing.md)
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search

    /// Not the stdlib `Result` — its `Failure` generic requires `Error`
    /// conformance, and the friendly, already-mapped message here is a plain
    /// `String` (`Self.friendlyMessage(for:)` already did the one-time
    /// error-to-copy conversion by the time this returns).
    private enum PageOutcome {
        case success(CoverSearchResponse)
        case failure(String)
    }

    private func requestPage(_ page: Int) async -> PageOutcome {
        do {
            return .success(try await searchProvider.search(query: trimmedQuery, page: page))
        } catch {
            return .failure(Self.friendlyMessage(for: error))
        }
    }

    private func runSearch() async {
        state = .loading
        switch await requestPage(1) {
        case .success(let response):
            guard !Task.isCancelled else { return } // a newer query already superseded this one
            currentPage = 1
            photos = response.photos
            hasNextPage = response.nextPage
            state = .loaded
        case .failure(let message):
            guard !Task.isCancelled else { return }
            state = .failed(message)
        }
    }

    private func loadMore() async {
        guard hasNextPage, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        switch await requestPage(currentPage + 1) {
        case .success(let response):
            currentPage += 1
            photos += response.photos
            hasNextPage = response.nextPage
        case .failure(let message):
            loadMoreError = message
        }
        isLoadingMore = false
    }

    // MARK: - Pick

    private func pick(_ photo: CoverSearchResponse.Photo) async {
        guard let uploaderUserId else {
            toast = "Sign in first, then try again."
            return
        }
        guard pickingPhotoId == nil else { return }
        pickingPhotoId = photo.id
        defer { pickingPhotoId = nil }
        do {
            let result = try await Self.processAndUpload(
                photo, for: uploaderUserId, downloader: downloader, uploadVia: SupabaseCoverBucket()
            )
            onPick(result.path, result.creditName, result.creditUrl)
            dismiss()
        } catch {
            toast = "Couldn\u{2019}t use that photo. Try again."
        }
    }

    // MARK: - Pure/testable helpers

    static let minimumQueryLength = 2
    static let debounceMilliseconds = 400
    static let pexelsHomeURL = URL(string: "https://www.pexels.com")!

    private static let idlePromptText = "Search for a photo to use as your cover \u{2014} try a place, a mood, or a color."

    static func shouldSearch(query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumQueryLength
    }

    /// The download -> process -> upload pipeline, factored out of the view
    /// so it's directly testable (mirrors `TripFormView.uploadCoverPhoto`'s
    /// shape, just without `@State` to mutate \u{2014} the caller applies
    /// the result to its own draft state once this returns). Prefers
    /// `large2x`, falling back to `large` only when `large2x` isn't a
    /// parseable URL (an empty string, in practice \u{2014} the edge
    /// function defensively defaults a missing Pexels field to `""`, never
    /// omits the key). Throws \u{2014} never returns a partial/placeholder
    /// result \u{2014} on any step's failure, same "atomic: no result
    /// without a fully successful pipeline" contract `CoverStorage.upload`
    /// itself already documents.
    static func processAndUpload(
        _ photo: CoverSearchResponse.Photo, for userId: UUID,
        downloader: CoverPhotoDownloading, uploadVia storage: AvatarBucketUploading
    ) async throws -> (path: String, creditName: String, creditUrl: String) {
        guard let remoteURL = URL(string: photo.src.large2x) ?? URL(string: photo.src.large) else {
            throw CoverSearchError.noUsableImageURL
        }
        let rawData = try await downloader.data(from: remoteURL)
        let jpeg = try await ImageProcessing.downsampledJPEG(rawData, maxPixelSize: ImageProcessing.coverMaxPixelSize)
        let path = try await CoverStorage.upload(jpeg, for: userId, via: storage)
        return (path, photo.photographerName, photo.photoPageUrl)
    }

    /// Maps `search-covers`' documented error responses (`~/repos/backend/
    /// projects/tripto/functions/search-covers/index.ts`) to one clear,
    /// friendly message each \u{2014} same "never surface a raw status code"
    /// contract as `PasteImportSheet.friendlyMessage(for:)`, whose exact
    /// shape this mirrors (`static` for the same direct-testability reason).
    static func friendlyMessage(for error: Error) -> String {
        guard let functionsError = error as? FunctionsError else {
            return "Something went wrong. Check your connection and try again."
        }
        switch functionsError {
        case .relayError:
            return "Something went wrong. Check your connection and try again."
        case .httpError(let code, _):
            switch code {
            case 401:
                return "You\u{2019}re signed out, so photos can\u{2019}t be searched right now. Sign back in and try again."
            case 429:
                return "You\u{2019}ve searched a lot recently \u{2014} try again in an hour."
            case 502, 503:
                return "Couldn\u{2019}t reach Pexels right now. Try again."
            default:
                return "Something went wrong. Try again."
            }
        }
    }
}

/// Thrown by `CoverSearchSheet.processAndUpload` when neither `large2x` nor
/// `large` is a usable URL \u{2014} not reachable in practice against the
/// real `search-covers` function (both are Pexels CDN URLs whenever a photo
/// is returned at all), but a network response is never trusted to hold
/// that assumption blindly.
enum CoverSearchError: Error, Equatable {
    case noUsableImageURL
}

// MARK: - Network seams

/// Abstraction over the one `search-covers` edge-function call this sheet
/// makes \u{2014} lets `TriptoTests` (hermetic, no network \u{2014}
/// CLAUDE.md) substitute a stub, mirroring `AvatarBucketUploading`'s seam.
protocol CoverSearchProviding: Sendable {
    func search(query: String, page: Int) async throws -> CoverSearchResponse
}

struct SupabaseCoverSearchProvider: CoverSearchProviding {
    func search(query: String, page: Int) async throws -> CoverSearchResponse {
        try await Supa.invoke("search-covers", params: CoverSearchRequest(query: query, page: page))
    }
}

/// Downloads a chosen search result's own image bytes \u{2014} the
/// "download" half of "download-then-upload" (`CoverStorage.upload` is the
/// other half). Injectable so `TriptoTests` can stub it, same reasoning as
/// `CoverSearchProviding` above.
protocol CoverPhotoDownloading: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionCoverPhotoDownloader: CoverPhotoDownloading {
    func data(from url: URL) async throws -> Data {
        try await URLSession.shared.data(from: url).0
    }
}

// MARK: - Wire types

/// `search-covers`'s request body \u{2014} plain camelCase, matching that
/// function's own `req.json()` shape exactly (see `Supa.invoke`'s doc
/// comment for why this bypasses `JSONCoding`'s snake_case conversion).
struct CoverSearchRequest: Encodable {
    let query: String
    let page: Int
}

/// `search-covers`'s response \u{2014} mirrors its own `SearchCoversResponse`/
/// `TrimmedPhoto` shape exactly (`~/repos/backend/projects/tripto/functions/
/// search-covers/index.ts`). `nextPage` is a plain Bool ("is there another
/// page" \u{2014} the function trims Pexels' own `next_page`, a URL string
/// or null, down to `Boolean(...)`), NOT a page number; a caller wanting the
/// next page just requests `page + 1` itself.
struct CoverSearchResponse: Decodable, Equatable {
    // A sibling of `Photo`, not nested inside it — SwiftLint caps nesting at
    // 1 level deep, and `Photo.src: Sources` resolves this unqualified name
    // fine from a sibling scope either way.
    struct Sources: Decodable, Equatable {
        let large2x: String
        let large: String
        let medium: String
    }

    struct Photo: Decodable, Equatable, Identifiable {
        let id: Int
        /// Defensively optional even though the function's own `TrimmedPhoto
        /// .alt` is defaulted server-side (never actually omitted today
        /// \u{2014} see that type's doc comment): a network response is
        /// never trusted to hold a client-side assumption forever. `nil` or
        /// blank both fall back to a plain "Photo" VoiceOver label
        /// (`accessibleDescription` below).
        let alt: String?
        let photographerName: String
        /// Same defensive-optional reasoning as `alt` \u{2014} unused by
        /// this sheet's own UI (the credit LINK target is `photoPageUrl`,
        /// not this), decoded only because it's part of the documented
        /// contract.
        let photographerUrl: String?
        let photoPageUrl: String
        let src: Sources

        var accessibleDescription: String {
            let trimmed = alt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "Photo" : trimmed
        }
    }

    let photos: [Photo]
    let page: Int
    let totalResults: Int
    let nextPage: Bool
}

#Preview {
    CoverSearchSheet(uploaderUserId: UUID(), onPick: { _, _, _ in })
}
