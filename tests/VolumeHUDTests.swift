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

import AppKit
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

/// What VoiceOver is given to say.
///
/// The panel is drawn, so it carries no text for VoiceOver to find, and the
/// sentence it speaks has to be built rather than read off the screen. That
/// makes it a decision with a wrong answer available, which is what puts it
/// here: it has to name the value, because "system dialog" — the role macOS
/// read out before this existed — announces that something happened without
/// saying what.
final class VolumeAnnouncementTests: XCTestCase {
    func testTheLevelIsSpokenAsAPercentage() {
        XCTAssertEqual(volumeAnnouncement(percent: 50, muted: false), "Volume 50%")
        XCTAssertEqual(volumeAnnouncement(percent: 0, muted: false), "Volume 0%")
        XCTAssertEqual(volumeAnnouncement(percent: 100, muted: false), "Volume 100%")
    }

    /// Muted says muted and drops the number. The level is still whatever it
    /// was, and reading it out would describe a display that is making no
    /// sound as though it were making some.
    func testMutedIsSpokenInsteadOfTheLevel() {
        XCTAssertEqual(volumeAnnouncement(percent: 50, muted: true), "Muted")
        XCTAssertEqual(volumeAnnouncement(percent: 0, muted: true), "Muted")
    }

    /// The number comes from a DDC read and can be anything, the same reason
    /// `EZVolumeChicletsLit` clamps. The bar and the sentence have to agree.
    func testAnOutOfRangeLevelIsClamped() {
        XCTAssertEqual(volumeAnnouncement(percent: -5, muted: false), "Volume 0%")
        XCTAssertEqual(volumeAnnouncement(percent: 150, muted: false), "Volume 100%")
    }
}

/// That the panel keeps out of the accessibility tree.
///
/// Two setter calls in an initializer, which is exactly the kind of thing that
/// gets dropped in a later edit without anyone noticing: nothing moves, nothing
/// logs, and the only symptom is a screen reader saying "system dialog" to
/// somebody who is not the person making the change.
///
/// The default is asserted alongside the result, because without it this reads
/// as a test of AppKit rather than of anything here. A borderless
/// non-activating panel *is* an accessibility element when it is built, and
/// that default is the entire cause of the bug.
final class VolumeHUDAccessibilityTests: XCTestCase {
    func testAPanelBuiltLikeThisOneIsAnAccessibilityElementUntilItIsToldOtherwise() {
        let fresh = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        fresh.level = .screenSaver
        XCTAssertTrue(fresh.isAccessibilityElement())
    }

    func testTheFeedbackPanelIsNotInTheAccessibilityTree() {
        let panel = VolumeHUD.shared.panel
        XCTAssertFalse(panel.isAccessibilityElement())
        XCTAssertEqual(panel.accessibilityRole(), .unknown)
    }
}
