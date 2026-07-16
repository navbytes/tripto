import Foundation
import Supabase

/// Wraps the real `trip-covers` bucket via `Supa.client.storage` — the only
/// conformance the app itself uses; tests supply their own throwing stub
/// (`AvatarBucketUploading`, shared with `AvatarStorage.swift` — the same
/// one upload seam, just a different concrete bucket).
struct SupabaseCoverBucket: AvatarBucketUploading {
    func upload(_ path: String, data: Data, options: FileOptions) async throws {
        try await Supa.client.storage.from(CoverStorage.bucket).upload(path, data: data, options: options)
    }
}

/// `trip-covers` bucket access (backend migration 20260715164057, plan D2):
/// public-read, owner-folder write RLS — identical shape to `AvatarStorage`,
/// deliberately kept as a plain SIBLING rather than threading a `bucket:`
/// parameter through that type (P8b brief's own call to make: "make a covers
/// sibling or generalize, your call"). Reasoning: the two are genuinely
/// distinct, diverging resources — a person's identity photo vs. a trip's
/// own cover, which alone grows the P8c `cover_credit_name`/`cover_credit_url`
/// columns this bucket helper has no reason to know about — and
/// `AvatarStorage`'s doc comments are avatar/profile-specific throughout
/// (its `Profile`/`TripProfile` uploader-folder reasoning), so generalizing
/// it would mean rewriting those to stay accurate for a bucket they were
/// never about. The actual duplicated surface is small and stable (one
/// upload path-builder, one URL-builder, ~15 lines) — cheaper to keep in
/// sync by hand than to abstract.
enum CoverStorage {
    static let bucket = "trip-covers"

    /// Same v1 replace policy as `AvatarStorage.upload` (identical
    /// reasoning, not repeated here): a fresh UUID filename every call, the
    /// old object orphaned (`docs/BACKLOG.md` candidate), atomic — this
    /// either returns the new path or throws, never partially writes one.
    /// `TripFormView`'s cover picker only ever assigns its draft
    /// `coverImagePath` from this call's RETURNED value inside a
    /// `do`/`catch`, so a thrown error leaves whatever path was already
    /// there (an existing photo, or none) untouched — the trip's stored row
    /// is never written until `save()`, so nothing here can race a
    /// half-applied cover onto it either.
    static func upload(
        _ jpegData: Data, for userId: UUID, via storage: AvatarBucketUploading = SupabaseCoverBucket()
    ) async throws -> String {
        // Owner-folder segment lowercased to match the RLS `auth.uid()::text`
        // check — see `AvatarStorage.upload`'s comment for the full reason
        // (Postgres `uuid::text` is lowercase, Foundation `uuidString` is
        // uppercase; an uppercase folder fails every authenticated upload).
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString).jpg"
        try await storage.upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg"))
        return path
    }

    /// See `AvatarStorage.publicURL(for:)` — identical path-not-URL builder,
    /// just this bucket's name instead.
    static func publicURL(for path: String) -> URL? {
        URL(string: "\(Config.SUPABASE_URL.absoluteString)/storage/v1/object/public/\(bucket)/\(path)")
    }
}
