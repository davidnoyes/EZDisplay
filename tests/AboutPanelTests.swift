//
//  AboutPanelTests.swift
//  EZDisplay
//
//  Tests for the geometry of the About window.
//
//  Layout is usually AppKit's problem and stays out of here, but two of its
//  defaults quietly did the wrong thing in this window and neither showed up
//  anywhere except in looking at it. A stopped spinner kept its width, so the
//  one button beside it was drawn off-center; and sizing the window to fit its
//  content let the wrapped paragraphs compress until they ran to the edges of
//  the frame. Both are measurable, so they are measured.
//

import AppKit
import XCTest

final class AboutPanelLayoutTests: XCTestCase {

    /// Mirrors the private constants in `AboutWindowController`. Duplicated
    /// deliberately: the point of the test is that the window really is built
    /// to these numbers, which reading them back from the source would not say.
    private let column: CGFloat = 320
    private let margin: CGFloat = 44

    private func laidOutContent() -> NSView {
        let content = AboutWindowController().window!.contentView!
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The cause of the off-center button, stated as AppKit's own behavior.
    /// `isDisplayedWhenStopped` reads as though it takes the spinner away; it
    /// only stops it drawing, and a stack view goes on reserving its width.
    func testAStoppedSpinnerStillTakesUpRoomUnlessItIsHidden() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.stopAnimation(nil)

        XCTAssertGreaterThan(spinner.intrinsicContentSize.width, 0)
    }

    /// So the spinner has to be hidden, and while nothing is running the check
    /// button is the only thing in its row and belongs in the middle of it.
    func testTheCheckButtonIsCenteredWhileNothingIsRunning() {
        let content = laidOutContent()
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }

        let visible = buttons.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(visible.map(\.title), ["Check for Updates"])

        let button = try! XCTUnwrap(visible.first)
        XCTAssertEqual(button.convert(button.bounds, to: content).midX,
                       content.bounds.midX,
                       accuracy: 0.5)
    }

    /// The window is sized to fit, so nothing but the text column decides how
    /// wide it is. Assert the width the margins depend on.
    func testTheWindowIsTheTextColumnPlusAMarginEitherSide() {
        XCTAssertEqual(laidOutContent().bounds.width, column + 2 * margin)
    }

    /// The row centers as a whole, so putting the spinner back must not shove
    /// the button off to one side again — it moves left and the spinner takes
    /// the space it left. Asserted on the row rather than the button, because
    /// while a check is running the row is what has to look right.
    func testTheButtonRowStaysCenteredWhileACheckIsRunning() {
        let controller = AboutWindowController()
        let content = controller.window!.contentView!

        controller.setBusy(true)
        content.layoutSubtreeIfNeeded()

        let spinners = descendants(of: content).compactMap { $0 as? NSProgressIndicator }
        XCTAssertEqual(spinners.filter { !$0.isHiddenOrHasHiddenAncestor }.count, 1)

        let row = try! XCTUnwrap(descendants(of: content)
            .compactMap { $0 as? NSStackView }
            .first { $0.orientation == .horizontal })
        XCTAssertEqual(row.convert(row.bounds, to: content).midX,
                       content.bounds.midX,
                       accuracy: 0.5)
    }

    /// The reset in `showWindow` has to undo the busy state as well as the
    /// status text. It is the one path that has to do everything an abandoned
    /// check would have done, and a spinner left turning says the panel is
    /// still working when it is not.
    func testReopeningTheWindowStopsASpinnerLeftRunning() {
        let controller = AboutWindowController()
        let content = controller.window!.contentView!
        let spinner = try! XCTUnwrap(
            descendants(of: content).compactMap { $0 as? NSProgressIndicator }.first)

        controller.setBusy(true)
        XCTAssertFalse(spinner.isHidden)

        controller.showWindow(nil)
        defer { controller.close() }

        XCTAssertTrue(spinner.isHidden)
    }

    /// The complaint that started this: the sentences ran up to the frame.
    /// Every one of them is a wrapping label whose width the layout is free to
    /// choose, which is exactly why this needs asserting rather than assuming.
    ///
    /// Measured on the alignment rect rather than the frame. That is what Auto
    /// Layout positions and what the reader sees; an `NSTextField` frame is a
    /// couple of points wider either side for a focus ring it never draws, so
    /// measuring frames says the text overhangs a margin it is sitting on.
    func testNoTextComesWithinAMarginOfTheEdge() {
        let content = laidOutContent()
        let labels = descendants(of: content).compactMap { $0 as? NSTextField }
        XCTAssertFalse(labels.isEmpty)

        for label in labels {
            let text = label.superview!.convert(
                label.alignmentRect(forFrame: label.frame), to: content)
            XCTAssertGreaterThanOrEqual(text.minX, margin, label.stringValue)
            XCTAssertLessThanOrEqual(text.maxX, content.bounds.width - margin,
                                     label.stringValue)
        }
    }

    /// A failure message runs to three lines and the window grows to hold it.
    /// The margin has to survive that: the status label is the one thing here
    /// whose size is not known when the window is built, so it is the one most
    /// able to push past the column, and it did.
    func testALongStatusGrowsTheWindowWithoutEatingTheMargin() {
        let controller = AboutWindowController()
        let content = controller.window!.contentView!
        content.layoutSubtreeIfNeeded()
        let idleHeight = content.bounds.height

        controller.announce(
            "EZDisplay could not be installed: the download finished but the "
            + "archive could not be unpacked, and the copy already on disk has "
            + "been left exactly as it was.")
        content.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(content.bounds.height, idleHeight)
        XCTAssertEqual(content.bounds.width, column + 2 * margin)

        for label in descendants(of: content).compactMap({ $0 as? NSTextField }) {
            let text = label.superview!.convert(
                label.alignmentRect(forFrame: label.frame), to: content)
            XCTAssertGreaterThanOrEqual(text.minX, margin, label.stringValue)
            XCTAssertLessThanOrEqual(text.maxX, content.bounds.width - margin,
                                     label.stringValue)
        }
    }
}
