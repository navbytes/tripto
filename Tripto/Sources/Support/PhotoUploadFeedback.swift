import OSLog

/// Stage-honest failure feedback for the photo pipeline (pick/download ->
/// `ImageProcessing.downsampledJPEG` -> `AvatarStorage`/`CoverStorage.upload`),
/// shared by all three upload call sites (`AvatarPhotoPicker`, `TripFormView`'s
/// cover picker, `CoverSearchSheet`). The old code collapsed every stage into
/// one generic toast, so the client bug report couldn't say which stage broke;
/// this splits "this photo is unusable" (prepare) from "the upload didn't land"
/// (network/rejected write) and logs the underlying error so the next report
/// names the stage instead of guessing.
enum PhotoUploadFeedback {
    private static let log = Logger(subsystem: "io.navbytes.tripto", category: "photo-upload")

    /// Maps a thrown pipeline error to a jargon-free, actionable toast and
    /// logs the underlying error. Logs only the stage, the error TYPE, and its
    /// `localizedDescription` (a status/RLS/network message) — never the
    /// storage path, the uid, or any key material.
    static func message(for error: Error) -> String {
        // `ImageProcessingError` is the only error the decode/downsample/encode
        // stage throws; anything else reaching the `catch` came from the
        // network upload (or, for `CoverSearchSheet`, the source download).
        let isPrepareFailure = error is ImageProcessingError
        let stage = isPrepareFailure ? "prepare" : "upload"
        let kind = String(describing: type(of: error))
        log.error("photo pipeline failed (\(stage, privacy: .public)): \(kind, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        return isPrepareFailure
            // The photo itself couldn't be decoded/resized — retrying the same
            // one won't help, a different photo will.
            ? "Couldn\u{2019}t prepare that photo. Try a different one."
            // The photo is fine, the request didn't go through — retrying is
            // the right action.
            : "Couldn\u{2019}t upload that photo. Check your connection and try again."
    }
}
