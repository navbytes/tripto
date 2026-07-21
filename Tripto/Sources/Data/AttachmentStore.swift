import Foundation

/// On-device cache for attachment bytes — `Application Support/Attachments/
/// <attachmentId>.<jpg|pdf>` — so a previously-downloaded (or just-uploaded)
/// boarding pass/voucher opens instantly and works offline
/// (`docs/PRODUCT_PLAN.md` §2.1: "attachments cache locally after first
/// view"). `AttachmentService` is the only writer; this type is pure
/// filesystem plumbing with no network/SwiftData dependency of its own, so
/// it never needs a protocol seam for tests — real `FileManager` I/O against
/// the simulator's own sandboxed Application Support directory is already
/// hermetic (no network).
enum AttachmentStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Attachments", isDirectory: true)
    }

    private static func fileURL(id: UUID, contentType: AttachmentContentType) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(contentType.fileExtension)")
    }

    /// `nil` when nothing is cached yet — the one check every render/prefetch
    /// call site makes before deciding whether a download is needed at all.
    static func cachedFileURL(id: UUID, contentType: AttachmentContentType) -> URL? {
        let url = fileURL(id: id, contentType: contentType)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Creates the cache directory if needed and marks it excluded from
    /// iCloud/iTunes backup (security audit S-1, ratified: the server is the
    /// source of truth for every attachment; this cache is re-downloadable,
    /// so it has no business riding along in a device backup). Idempotent —
    /// `createDirectory(withIntermediateDirectories: true)` no-ops if the
    /// directory already exists, and re-setting the resource value on every
    /// `write` is cheap and self-healing if it's ever lost (e.g. the
    /// directory was recreated).
    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    /// Writes (or overwrites) the cached copy and returns its URL.
    /// `.completeFileProtection` at rest — same posture as
    /// `TripArchiveExporter.writeTempFile` for the same reason: these bytes
    /// carry PII/confirmation codes (boarding passes, hotel vouchers).
    @discardableResult
    static func write(_ data: Data, id: UUID, contentType: AttachmentContentType) throws -> URL {
        try ensureDirectory()
        let url = fileURL(id: id, contentType: contentType)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Best-effort — `AttachmentService.delete` doesn't need this to
    /// succeed; a leftover cache file for a since-deleted row is harmless
    /// (nothing references its id anymore, so it's never rendered again).
    static func remove(id: UUID, contentType: AttachmentContentType) {
        try? FileManager.default.removeItem(at: fileURL(id: id, contentType: contentType))
    }

    /// Security audit S-1: the whole cache is per-account bytes (boarding
    /// passes, vouchers) that must not survive sign-out on a shared device —
    /// `SyncStore.wipeAll`/`SyncEngine.wipeForSignOut` already clear every
    /// mirrored row, but rows are not bytes, so this is the matching
    /// filesystem half. Best-effort (mirrors `remove(id:contentType:)`); a
    /// leftover directory with no matching local row is never rendered
    /// (`AttachmentStrip` only ever looks up by an `ItemAttachment.id` that
    /// exists locally) and self-heals on the next `write`.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // ponytail: no eviction/size ceiling — the 10 files/item x 10MB cap
    // keeps a single trip's worst case in the tens-of-MB range, and only a
    // handful of trips are ever "current" on one device. Add an LRU sweep
    // (oldest `createdAt`/last-opened first) if usage data ever shows this
    // matters — no such job exists in v1.
}
