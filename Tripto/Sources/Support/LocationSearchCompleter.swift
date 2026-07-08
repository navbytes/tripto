import Foundation
import MapKit

/// On-device place autocomplete for the add-item location field (this
/// milestone's brief §4.3: "plain text + MKLocalSearchCompleter on-device
/// suggestions ... NO Google APIs"). A thin `MKLocalSearchCompleterDelegate`
/// wrapper exposing `results` as `@Observable` state so `LocationField` can
/// drive a suggestions list directly off it.
@Observable
final class LocationSearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        completer.queryFragment = query
    }

    func clear() {
        results = []
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    /// Resolves a tapped suggestion to a coordinate. Best-effort — a plain
    /// text fallback with no coordinate is still an acceptable save
    /// (BUILD_PLAN.md §4.3: "in v1 plain text is acceptable"), so callers
    /// treat a `nil` result as "leave lat/lng unset," not an error.
    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return nil }
        return response.mapItems.first?.placemark.coordinate
    }
}
