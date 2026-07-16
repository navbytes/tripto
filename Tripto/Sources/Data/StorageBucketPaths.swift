import Foundation

/// The upload-path scheme and public-URL shape shared by every public-read,
/// owner-folder-RLS Storage bucket this app uses (`AvatarStorage`/
/// `CoverStorage`) — the actually-duplicated surface had no per-bucket logic
/// at all, so it lives once here; each facade keeps its own bucket-specific
/// doc comments (P8a/P8b/P8c reasoning) rather than this type generalizing
/// over them.
enum StorageBucketPaths {
    /// v1 replace policy (plan D2, deliberately pragmatic): every call mints
    /// a fresh UUID filename rather than overwriting the previous object, so
    /// a stale in-flight download can never race a fresh upload for the same
    /// name — see `AvatarStorage.upload`/`CoverStorage.upload`'s own doc
    /// comments for the full atomicity contract, not repeated here.
    ///
    /// The uid FOLDER segment is lowercased so it matches the storage write
    /// RLS `(storage.foldername(name))[1] = auth.uid()::text` (backend
    /// migration 20260715164057): Postgres renders `uuid::text` lowercase,
    /// but Foundation's `UUID.uuidString` is UPPERCASE — an unlowercased
    /// folder fails the policy's `with check` on every authenticated upload
    /// (the client-reported "couldn't use that photo" failure). Only
    /// segment [1] is checked, so the filename's case is irrelevant;
    /// lowercasing the uid alone is the whole fix — load-bearing, one home.
    static func ownerScopedPath(for userId: UUID) -> String {
        "\(userId.uuidString.lowercased())/\(UUID().uuidString).jpg"
    }

    /// Path, not URL, is what's stored (plan D3) — the pure builder each
    /// bucket derives a renderable URL from, matching the exact
    /// `{project}/storage/v1/object/public/{bucket}/{path}` shape
    /// supabase-swift's own `StorageFileApi.getPublicURL` builds (every
    /// bucket here is public-read, so this is a plain string join, never a
    /// signed/expiring URL — no network/auth needed to derive it).
    static func publicURL(bucket: String, path: String) -> URL? {
        URL(string: "\(Config.SUPABASE_URL.absoluteString)/storage/v1/object/public/\(bucket)/\(path)")
    }
}
