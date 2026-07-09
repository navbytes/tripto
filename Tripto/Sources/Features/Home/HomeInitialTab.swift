import Foundation

/// Pure decision helper for which tab `HomeView` should land on the first
/// time trips are available this session (UX audit finding 1: a user whose
/// trips are all in the past opened the app to the default "Upcoming" tab
/// and saw an empty screen, reading as "my trips are gone"). No SwiftUI
/// import on purpose — `HomeView` owns the actual `selectedTab` state; this
/// only owns the branching logic, so it's directly unit-testable without
/// standing up a view hierarchy (mirrors `HomeEmptyPlaceholder`'s house
/// pattern).
enum HomeInitialTab {
    /// Redirects to "Past" only when the default "Upcoming" tab would
    /// otherwise render empty *and* "Past" actually has content — so the
    /// redirect can never hide content the user would otherwise see.
    static func resolve(hasUpcoming: Bool, hasPast: Bool) -> String {
        if !hasUpcoming && hasPast {
            return "Past"
        }
        return "Upcoming"
    }
}
