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
}
