import Supabase

/// DRY finding L5: `CoverSearchSheet.friendlyMessage(for:)` (`search-covers`)
/// and `PasteImportSheet.friendlyMessage(for:)` (`ingest-text`) each wrapped
/// an identical "never surface a raw status code" skeleton around their own
/// per-endpoint HTTP-code strings — same generic fallback for a
/// non-`FunctionsError`/`.relayError` and for any code the endpoint doesn't
/// document. This owns that skeleton once; both views keep their own
/// `static friendlyMessage(for:)` (callable directly from
/// `PasteImportSheetFriendlyMessageTests`/`CoverSearchSheetTests`, same as
/// before) as a thin wrapper passing their own `perCode` strings.
enum FriendlyFunctionsMessage {
    /// `perCode` maps an HTTP status the calling endpoint documents to its
    /// own friendly string; any other code — including every endpoint's
    /// shared "give up" case — falls back to the same generic message every
    /// caller already used.
    static func map(_ error: Error, perCode: [Int: String]) -> String {
        guard let functionsError = error as? FunctionsError else {
            return "Something went wrong. Check your connection and try again."
        }
        switch functionsError {
        case .relayError:
            return "Something went wrong. Check your connection and try again."
        case .httpError(let code, _):
            return perCode[code] ?? "Something went wrong. Try again."
        }
    }
}
