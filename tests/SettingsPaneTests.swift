//
//  SettingsPaneTests.swift
//  EZDisplay
//
//  Tests for which pane the Settings window opens on.
//
//  A stored pane identifier outlives the pane. Someone reorders the tabs, or a
//  release drops one, and the value sitting in UserDefaults from last week now
//  matches nothing — at which point `firstIndex(of:)` returns nil and the
//  obvious spelling of this hands `selectedTabViewItemIndex` a -1. The window
//  opens on no pane at all, once, for the people who had used the pane that
//  went, and never for anyone testing the change.
//
//  So the lookup is a function rather than a line, and this is what it is for.
//

import XCTest

final class SettingsPaneTests: XCTestCase {

    private let panes = ["display", "audio", "general"]

    func testAStoredPaneIsTheOneReopened() {
        XCTAssertEqual(EZSettingsPane.index(of: "general", in: panes), 2)
    }

    func testTheFirstPaneIsTheOneReopenedWhenNothingIsStored() {
        XCTAssertEqual(EZSettingsPane.index(of: nil, in: panes), 0)
    }

    /// The case this exists for: a pane that has gone.
    func testAnUnknownPaneFallsBackToTheFirst() {
        XCTAssertEqual(EZSettingsPane.index(of: "keyboard", in: panes), 0)
    }

    /// Not -1, and not a crash. There is no sensible answer, and the caller is
    /// about to use this as an index.
    func testNoPanesAtAllStillAnswersZero() {
        XCTAssertEqual(EZSettingsPane.index(of: "display", in: []), 0)
    }

    /// Identifiers are matched exactly. They are stored values, not display
    /// names, so a case-insensitive match would only paper over a typo.
    func testTheMatchIsExact() {
        XCTAssertEqual(EZSettingsPane.index(of: "Display", in: panes), 0)
    }

    // MARK: Which panes there are

    /// Night Shift belongs beside Display, because that is what it changes.
    /// Order is asserted whole rather than by position, since the point of the
    /// list is the reading order of the toolbar.
    func testNightShiftSitsNextToDisplay() {
        XCTAssertEqual(EZSettingsPane.panes(nightShiftSupported: true).map(\.rawValue),
                       ["display", "nightshift", "audio", "general"])
    }

    /// An empty pane says the feature is there and broken. A Mac that cannot do
    /// Night Shift is offered no tab at all, the way the menu drops the item.
    func testAMacWithoutNightShiftIsNotOfferedThePane() {
        XCTAssertEqual(EZSettingsPane.panes(nightShiftSupported: false).map(\.rawValue),
                       ["display", "audio", "general"])
    }

    /// Every pane reopens on itself, over the list this build really has.
    ///
    /// The tests above pin the list and the ones above those pin the lookup,
    /// and nothing joined the two — which is how inserting Night Shift moved a
    /// stored "general" from index 2 to index 3 without a single test noticing.
    /// The positions are written out rather than derived from the same list, so
    /// a reorder fails here as well as in the list test.
    func testEveryPaneReopensOnItself() {
        let identifiers = EZSettingsPane.panes(nightShiftSupported: true).map(\.rawValue)
        XCTAssertEqual(EZSettingsPane.index(of: "display", in: identifiers), 0)
        XCTAssertEqual(EZSettingsPane.index(of: "nightshift", in: identifiers), 1)
        XCTAssertEqual(EZSettingsPane.index(of: "audio", in: identifiers), 2)
        XCTAssertEqual(EZSettingsPane.index(of: "general", in: identifiers), 3)
    }

    /// The two halves together: this is now the way a stored pane really can
    /// name one that is not there, so it is worth pinning as one case rather
    /// than trusting that the lookup and the list agree.
    func testAStoredNightShiftPaneFallsBackWhereItIsUnsupported() {
        let identifiers = EZSettingsPane.panes(nightShiftSupported: false).map(\.rawValue)
        XCTAssertEqual(EZSettingsPane.index(of: "nightshift", in: identifiers), 0)
    }
}
