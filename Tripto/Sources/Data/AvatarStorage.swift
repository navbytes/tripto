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
    /// calling `.remove` on the bucket.
    ///
    /// Atomicity (P8a brief): this either returns the new path or throws —
    /// it never mutates any model/row itself. Callers write the returned
    /// path to `Profile.avatarPath`/`TripProfile.avatarPath` only after
    /// `await`ing this successfully, so a thrown error leaves whatever path
    /// was already there untouched.
    static func upload(
        _ jpegData: Data, for userId: UUID, via storage: AvatarBucketUploading = SupabaseAvatarBucket()
    ) async throws -> String {
        // The uid FOLDER segment is lowercased so it matches the storage
        // write RLS `(storage.foldername(name))[1] = auth.uid()::text`
        // (backend migration 20260715164057): Postgres renders `uuid::text`
        // lowercase, but Foundation's `UUID.uuidString` is UPPERCASE — an
        // unlowercased folder fails the policy's `with check` on every
        // authenticated upload (the client-reported "couldn't use that photo"
        // failure). Only segment [1] is checked, so the filename's case is
        // irrelevant; lowercasing the uid alone is the whole fix.
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString).jpg"
        try await storage.upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg"))
        return path
    }

    /// Path, not URL, is what's stored (plan D3) — this is the pure builder
    /// the app derives a renderable URL from, matching the exact
    /// `{project}/storage/v1/object/public/{bucket}/{path}` shape
    /// supabase-swift's own `StorageFileApi.getPublicURL` builds (`avatars`
    /// is a public-read bucket, so this is a plain string join, never a
    /// signed/expiring URL — no network/auth needed to derive it).
    static func publicURL(for path: String) -> URL? {
        URL(string: "\(Config.SUPABASE_URL.absoluteString)/storage/v1/object/public/\(bucket)/\(path)")
    }
}
