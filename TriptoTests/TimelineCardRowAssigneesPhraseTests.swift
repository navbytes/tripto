import XCTest
@testable import Tripto

/// UX audit finding F4: `TimelineCardRow.assigneesPhrase(for:)` — names beat
/// a bare count when every assignee's `AvatarStack.Person.name` is
/// available, with a 1/2/3/4+ pluralization ladder and a fallback to the
/// old "N people" wording whenever any name is missing (an older call site
/// that hasn't threaded a name through yet).
final class TimelineCardRowAssigneesPhraseTests: XCTestCase {
    private func person(_ name: String) -> AvatarStack.Person {
        AvatarStack.Person(id: UUID(), initial: String(name.prefix(1)), colorName: "amber", name: name)
    }

    func testOneName() {
        XCTAssertEqual(TimelineCardRow.assigneesPhrase(for: [person("Meera")]), "for Meera")
    }

    func testTwoNames() {
        XCTAssertEqual(
            TimelineCardRow.assigneesPhrase(for: [person("Meera"), person("Dev")]),
            "for Meera and Dev"
        )
    }

    func testThreeNames() {
        XCTAssertEqual(
            TimelineCardRow.assigneesPhrase(for: [person("Meera"), person("Dev"), person("Kiran")]),
            "for Meera, Dev, and Kiran"
        )
    }

    func testFourOrMoreNamesOverflowsToTheFirstTwoPlusACount() {
        XCTAssertEqual(
            TimelineCardRow.assigneesPhrase(for: [person("Meera"), person("Dev"), person("Kiran"), person("Priya")]),
            "for Meera, Dev, and 2 others"
        )
    }

    func testAnEmptyNameFallsBackToTheBareCountWording() {
        let assignees = [person("Meera"), AvatarStack.Person(id: UUID(), initial: "D", colorName: "moss")]
        XCTAssertEqual(TimelineCardRow.assigneesPhrase(for: assignees), "for 2 people")
    }

    func testASingleAssigneeWithNoNameUsesSingularWording() {
        let assignees = [AvatarStack.Person(id: UUID(), initial: "D", colorName: "moss")]
        XCTAssertEqual(TimelineCardRow.assigneesPhrase(for: assignees), "for 1 person")
    }
}
