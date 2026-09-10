//
//  VolumeHUDTests.swift
//  EZDisplay
//
//  Tests for the one decision in src/VolumeHUD.swift that is not drawing: how
//  the Sound pane's feedback setting reads.
//
//  The panel and the click are I/O and stay out. Reading the raw defaults value
//  is I/O too. Deciding what that value means is not, and it is the part with a
//  wrong answer available: default it the other way and the click goes silent
//  for everyone who has never opened the Sound pane, which is most people, with
//  nothing on screen to say why.
//

import XCTest

final class VolumeFeedbackSettingTests: XCTestCase {
    /// The case that carries the whole risk. macOS writes the key only once the
    /// box has been unticked and reticked, so on a machine that has never been
    /// touched there is nothing to read — and the box is ticked.
    func testAnAbsentSettingIsOn() {
        XCTAssertTrue(volumeFeedbackEnabled(nil))
    }

    func testTheSettingIsReadWhenItIsThere() {
        XCTAssertTrue(volumeFeedbackEnabled(NSNumber(value: 1)))
        XCTAssertFalse(volumeFeedbackEnabled(NSNumber(value: 0)))
        XCTAssertTrue(volumeFeedbackEnabled(NSNumber(value: true)))
        XCTAssertFalse(volumeFeedbackEnabled(NSNumber(value: false)))
    }

    /// A defaults domain is shared and writable by anything, so the value is
    /// whatever was last put there. Something unreadable falls the same way as
    /// nothing at all: the click stays, because losing it silently is the worse
    /// of the two failures.
    func testSomethingThatIsNotANumberIsTreatedAsAbsent() {
        XCTAssertTrue(volumeFeedbackEnabled("yes"))
        XCTAssertTrue(volumeFeedbackEnabled([1, 2, 3]))
    }
}
