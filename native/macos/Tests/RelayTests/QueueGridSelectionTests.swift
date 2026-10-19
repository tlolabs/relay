import XCTest
@testable import Relay

final class QueueGridSelectionTests: XCTestCase {
    private let ids = ["a", "b", "c", "d", "e", "f", "g"]

    func testShiftNavigationExtendsAndContractsFromTheOriginalAnchor() {
        var grid = QueueGridSelection()
        var selected = grid.select("b", in: ids, selected: [])
        // A three-column layout moves down one row, selecting the range.
        selected = grid.move(by: 3, in: ids, selected: selected, extending: true)
        XCTAssertEqual(selected, ["b", "c", "d", "e"])
        selected = grid.move(by: -1, in: ids, selected: selected, extending: true)
        XCTAssertEqual(selected, ["b", "c", "d"])
        selected = grid.move(by: -3, in: ids, selected: selected, extending: true)
        XCTAssertEqual(selected, ["a", "b"])
        XCTAssertEqual(grid.anchor, "b")
        XCTAssertEqual(grid.cursor, "a")
        selected = grid.move(by: 1, in: ids, selected: selected, extending: false)
        XCTAssertEqual(selected, ["b"])
        XCTAssertEqual(grid.anchor, "b")
    }

    func testCommandToggleAndAdditiveRangesKeepCursorInsideSelection() {
        var grid = QueueGridSelection()
        var selected = grid.select("b", in: ids, selected: [])
        selected = grid.select("f", in: ids, selected: selected, toggling: true)
        XCTAssertEqual(selected, ["b", "f"])
        selected = grid.select("g", in: ids, selected: selected, extending: true, toggling: true)
        XCTAssertEqual(selected, ["b", "f", "g"])
        selected = grid.select("g", in: ids, selected: selected, toggling: true)
        XCTAssertEqual(selected, ["b", "f"])
        XCTAssertTrue(selected.contains(grid.cursor!))
        selected = grid.select("b", in: ids, selected: selected, toggling: true)
        selected = grid.select("f", in: ids, selected: selected, toggling: true)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertNil(grid.cursor)
        XCTAssertNil(grid.anchor)
    }

    func testSelectionSurvivesLayoutSwitchAndResetsWhenFilterHidesIt() {
        var grid = QueueGridSelection()
        _ = grid.select("b", in: ids, selected: [])
        grid.reconcile(in: ids, selected: ["e", "g"])
        XCTAssertEqual(grid.cursor, "e")
        XCTAssertEqual(grid.anchor, "e")
        XCTAssertEqual(grid.move(by: 2, in: ids, selected: ["e", "g"], extending: true), ["e", "f", "g"])
        grid.reconcile(in: ["a", "c"], selected: ["e", "g"])
        XCTAssertNil(grid.cursor)
        XCTAssertEqual(grid.move(by: 2, in: ["a", "c"], selected: [], extending: false), ["a"])
    }

    func testMovementClampsAtEdgesAndSelectAllUsesVisibleJobsOnly() {
        var grid = QueueGridSelection()
        var selected = grid.select("g", in: ids, selected: [])
        selected = grid.move(by: 3, in: ids, selected: selected, extending: false)
        XCTAssertEqual(selected, ["g"])
        selected = grid.move(by: -ids.count, in: ids, selected: selected, extending: false)
        XCTAssertEqual(selected, ["a"])
        selected = grid.move(by: -1, in: ids, selected: selected, extending: false)
        XCTAssertEqual(selected, ["a"])
        selected = grid.selectAll(in: ["c", "e"], selected: selected)
        XCTAssertEqual(selected, ["c", "e"])
        XCTAssertEqual(grid.cursor, "c")
        XCTAssertEqual(grid.move(by: 1, in: [], selected: selected, extending: false), [])
        XCTAssertNil(grid.cursor)
    }

    func testRemovalKeepsPositionOrPreviousLastItemAndHandlesEmptyQueue() {
        XCTAssertEqual(QueueGridSelection.replacement(for: "b", oldIDs: ids, newIDs: ["a", "c", "d"]), "c")
        XCTAssertEqual(QueueGridSelection.replacement(for: "g", oldIDs: ids, newIDs: ["a", "c"]), "c")
        XCTAssertNil(QueueGridSelection.replacement(for: "b", oldIDs: ids, newIDs: []))
        XCTAssertNil(QueueGridSelection.replacement(for: "b", oldIDs: ids, newIDs: ids))
    }
}
