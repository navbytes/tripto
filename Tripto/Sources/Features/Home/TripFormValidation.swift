import Foundation

/// Pure validation rules for `TripFormView`, factored out so they're
/// directly unit testable with no SwiftUI/SwiftData involved.
enum TripFormValidation {
    static func isTitleValid(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Inline validation rule: the end date must be on or after the start
    /// date (BUILD_PLAN.md §4.1).
    static func isDateRangeValid(startDate: Date, endDate: Date) -> Bool {
        endDate >= startDate
    }

    /// Resolves a 2-letter ISO region code to its localized country name, or
    /// `nil` when the code isn't a real, assigned region — e.g. `"PO"` isn't
    /// Portugal's code (that's `"PT"`) but `Locale.localizedString(forRegionCode:)`
    /// echoes it back unchanged rather than returning `nil`, so assignment is
    /// verified against `Locale.Region.isoRegions` first (finding F2).
    static func countryName(forCode code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 2, trimmed.allSatisfy(\.isLetter) else { return nil }
        let region = Locale.Region(trimmed)
        guard Locale.Region.isoRegions.contains(region) else { return nil }
        return Locale.current.localizedString(forRegionCode: trimmed)
    }

    /// The country field is optional, so a blank value is acceptable; once
    /// something is entered it must resolve to a real country (finding F2).
    static func isCountryCodeAcceptable(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return countryName(forCode: trimmed) != nil
    }

    static func isValid(title: String, countryCode: String, startDate: Date, endDate: Date) -> Bool {
        isTitleValid(title)
            && isCountryCodeAcceptable(countryCode)
            && isDateRangeValid(startDate: startDate, endDate: endDate)
    }

    /// Derives the regional-indicator flag emoji (e.g. "PT" -> "\u{1F1F5}\u{1F1F9}")
    /// for a 2-letter ISO region code, so a resolved country name reads with
    /// its flag rather than as plain text that's visually identical to
    /// passive helper copy (finding F2). `nil` for anything that doesn't
    /// resolve to a real, assigned region — reuses `countryName(forCode:)`'s
    /// validation so the two can never disagree.
    static func flagEmoji(forCode code: String) -> String? {
        guard countryName(forCode: code) != nil else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let base = Unicode.Scalar("A").value
        var scalars = String.UnicodeScalarView()
        for character in trimmed.unicodeScalars {
            guard let regionalIndicator = Unicode.Scalar(0x1F1E6 + (character.value - base)) else { return nil }
            scalars.append(regionalIndicator)
        }
        return String(scalars)
    }
}
