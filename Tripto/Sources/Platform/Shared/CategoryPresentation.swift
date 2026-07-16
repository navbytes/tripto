import SwiftUI

/// Category → SF Symbol + `CategoryColor` pair + display label (DRY M1
/// #3) — the pure mapping shared by the app's `ItemCategory`
/// (`Design/Components/CategoryIcon.swift` forwards here via a case-by-case
/// bridge, since `ItemCategory` itself lives in `Models/`, off-limits to
/// the widget extension) and the widget's own `SnapshotItem.Category`
/// (declared alongside this file in `Platform/Shared`). Keeps the app's
/// icon/label/color and the widget/Live Activity's in permanent lockstep —
/// a new category only ever needs adding here once.
extension SnapshotItem.Category {
    public var colorPair: CategoryColor.Pair {
        switch self {
        case .flight: CategoryColor.flight
        case .hotel: CategoryColor.hotel
        case .activity: CategoryColor.activity
        case .food: CategoryColor.food
        case .transport: CategoryColor.transport
        }
    }

    public var symbolName: String {
        switch self {
        case .flight: "airplane"
        case .hotel: "bed.double.fill"
        case .activity: "camera.fill"
        case .food: "fork.knife"
        case .transport: "car.fill"
        }
    }

    public var displayName: String {
        switch self {
        case .flight: "Flight"
        case .hotel: "Stay"
        case .activity: "Activity"
        case .food: "Food"
        case .transport: "Transport"
        }
    }
}
