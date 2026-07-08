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

    static func isValid(title: String, startDate: Date, endDate: Date) -> Bool {
        isTitleValid(title) && isDateRangeValid(startDate: startDate, endDate: endDate)
    }
}
