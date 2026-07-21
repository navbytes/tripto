import Foundation
import Supabase

/// Abstraction over the three Supabase Storage calls `AttachmentService`
/// makes against the private `item-attachments` bucket — same "let tests
/// substitute a stub, `TriptoTests` never touch a live network/auth
/// session" role `AvatarBucketUploading` plays for the public covers/avatars
/// buckets (`AvatarStorage.swift`), widened to cover download/remove too
/// since this bucket (unlike those) is read from as well as written to.
protocol AttachmentBucketAccessing: Sendable {
    func upload(_ path: String, data: Data, options: FileOptions) async throws
    func remove(paths: [String]) async throws
    func download(_ path: String) async throws -> Data
}

/// Wraps the real `item-attachments` bucket via `Supa.client.storage` — the
/// only conformance the app itself uses; tests supply their own stub.
struct SupabaseAttachmentBucket: AttachmentBucketAccessing {
    func upload(_ path: String, data: Data, options: FileOptions) async throws {
        try await Supa.client.storage.from(AttachmentStorage.bucket).upload(path, data: data, options: options)
    }

    func remove(paths: [String]) async throws {
        _ = try await Supa.client.storage.from(AttachmentStorage.bucket).remove(paths: paths)
    }

    func download(_ path: String) async throws -> Data {
        try await Supa.client.storage.from(AttachmentStorage.bucket).download(path: path)
    }
}

/// `item-attachments` bucket access (release 1.2, `.claude/company/
/// release-1.2/PLAN.md` C1): PRIVATE, trip-membership-scoped RLS on both the
/// table and storage objects — the deliberate opposite of `AvatarStorage`/
/// `CoverStorage`'s public-read pattern (CLAUDE.md: "NOT the public-read
/// covers pattern — these files carry PII and codes"). `StorageBucketPaths`
/// scopes itself in its own doc comment to "every public-read... bucket this
/// app uses," and its `publicURL` builder would be actively wrong here
/// (constructing an unauthenticated URL against a bucket where `public =
/// false` just 400s) — this bucket only ever reads via `storage.download`
/// (`AttachmentService.localFileURL`), never a URL. What IS shared with
/// `StorageBucketPaths` is the one RULE, not the code: path segments are
/// lowercased UUIDs, since storage RLS policies compare
/// `(storage.foldername(name))[1]`/`[2]` against Postgres's own lowercase
/// `uuid::text` rendering — see that type's `ownerScopedPath` doc comment
/// for the exact "Couldn't use that photo"-shaped failure this avoids.
enum AttachmentStorage {
    static let bucket = "item-attachments"

    /// `'<tripId>/<itemId>/<uuid>.<jpg|pdf>'` (C1). `attachmentId` doubles as
    /// both the row's own local/server `id` and the object's filename, so
    /// there's exactly one uuid to mint per attachment, not two.
    static func path(tripId: UUID, itemId: UUID, attachmentId: UUID, contentType: AttachmentContentType) -> String {
        "\(tripId.uuidString.lowercased())/\(itemId.uuidString.lowercased())/"
            + "\(attachmentId.uuidString.lowercased()).\(contentType.fileExtension)"
    }

    static func upload(
        _ data: Data, path: String, contentType: AttachmentContentType,
        via storage: AttachmentBucketAccessing = SupabaseAttachmentBucket()
    ) async throws {
        try await storage.upload(path, data: data, options: FileOptions(contentType: contentType.rawValue))
    }

    /// Best-effort at the CALLER's discretion (`AttachmentService.delete`
    /// `try?`s this) — orphaning the storage object on a failed remove is
    /// accepted, same v1 policy `AvatarStorage`/`CoverStorage` already
    /// documented for a replaced photo's old object.
    static func remove(
        path: String, via storage: AttachmentBucketAccessing = SupabaseAttachmentBucket()
    ) async throws {
        try await storage.remove(paths: [path])
    }

    static func download(
        path: String, via storage: AttachmentBucketAccessing = SupabaseAttachmentBucket()
    ) async throws -> Data {
        try await storage.download(path)
    }
}
