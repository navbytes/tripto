import Foundation
import Supabase

/// Abstraction over the one Supabase Storage call `AvatarStorage.upload`
/// makes — lets tests substitute a stub that fails (`TriptoTests` are
/// hermetic per CLAUDE.md, so nothing here may touch a live network/auth
/// session), exercising the "no path write on failed upload" atomicity rule
/// (P8a brief) without a live network/auth session.
protocol AvatarBucketUploading: Sendable {
    func upload(_ path: String, data: Data, options: FileOptions) async throws
}

/// Wraps the real `avatars` bucket via `Supa.client.storage` — the only
/// conformance the app itself uses; tests supply their own throwing stub.
struct SupabaseAvatarBucket: AvatarBucketUploading {
    func upload(_ path: String, data: Data, options: FileOptions) async throws {
        try await Supa.client.storage.from(AvatarStorage.bucket).upload(path, data: data, options: options)
    }
}

/// `avatars` bucket access (backend migration 20260715164057, plan D2):
/// public-read, owner-folder write RLS — `(storage.foldername(name))[1] =
/// auth.uid()::text`. Every call here is scoped under the CURRENTLY
/// authenticated (acting) user's own folder, regardless of whose photo it
/// ends up being — a `Profile` is always self-edited, but a `TripProfile`
/// photo (`TripProfileFormSheet`) can be for any trip profile an organizer
/// edits, including a no-account kid/grandparent who has no `auth.uid()` of
/// their own. RLS checks the uploader's folder, never the subject's id, so
/// `for userId:` below is always the acting/signed-in user
/// (`AuthManager.userId`), never the row the photo will be attached to.
enum AvatarStorage {
    static let bucket = "avatars"

    /// v1 replace policy (plan D2, deliberately pragmatic): every call mints
    /// a fresh UUID filename rather than overwriting the previous object, so
    /// a stale in-flight download can never race a fresh upload for the same
    /// name. The old object (if any) is left behind — orphans accepted in
    /// v1, no cleanup job (`docs/BACKLOG.md` candidate); "Remove photo"
    /// follows the same policy by only ever clearing the path column, never
    /// calling `.remove` on the bucket. Path scheme itself (owner-folder +
    /// fresh filename, lowercased uid for the RLS check) is
    /// `StorageBucketPaths.ownerScopedPath`'s one home, shared with
    /// `CoverStorage` — see that type's doc comment for why the uid is
    /// lowercased.
    ///
    /// Atomicity (P8a brief): this either returns the new path or throws —
    /// it never mutates any model/row itself. Callers write the returned
    /// path to `Profile.avatarPath`/`TripProfile.avatarPath` only after
    /// `await`ing this successfully, so a thrown error leaves whatever path
    /// was already there untouched.
    static func upload(
        _ jpegData: Data, for userId: UUID, via storage: AvatarBucketUploading = SupabaseAvatarBucket()
    ) async throws -> String {
        let path = StorageBucketPaths.ownerScopedPath(for: userId)
        try await storage.upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg"))
        return path
    }

    /// Path, not URL, is what's stored (plan D3) — see `StorageBucketPaths
    /// .publicURL(bucket:path:)`, this bucket's one-line facade onto it.
    static func publicURL(for path: String) -> URL? {
        StorageBucketPaths.publicURL(bucket: bucket, path: path)
    }
}
