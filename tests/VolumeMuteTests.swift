//
//  VolumeMuteTests.swift
//  EZDisplay
//
//  Tests for what a volume write does to the display's mute state.
//
//  Two rules meet here and both of them are about a display that is not doing
//  what the row says it is. Muting does not move the dial, so a display muted at
//  50 and a display playing at 50 read back identically; the row's own `isMuted`
//  is the only record of which one it is, and every one of these cases is a way
//  of getting that record wrong.
//
//  The pair also has to stay a pair. Turned on, the option mutes at the bottom
//  of the dial and the unmute rule lifts it on the way back up, and if either
//  side fires when the other should the display sticks silent — a volume key
//  that moves the slider and produces nothing, which is the fault this whole
//  feature was reported as.
//

import XCTest

final class VolumeMuteTests: XCTestCase {

    // MARK: - Coming back up

    /// The rule that was here before the option existed, and the reason it was:
    /// a muted display asked for more sound unmutes, the way macOS's own keys do.
    func testVolumeAboveZeroLiftsMute() {
        XCTAssertEqual(EZVolumeMute.action(percent: 10, muted: true, muteAtZero: false), .unmute)
    }

    /// Whether the option is on makes no difference above zero. It is about the
    /// bottom of the dial and nothing else, and an unmute that depended on it
    /// would leave anyone with it turned on unable to get the sound back.
    func testTheOptionDoesNotChangeWhatHappensAboveZero() {
        XCTAssertEqual(EZVolumeMute.action(percent: 10, muted: true, muteAtZero: true), .unmute)
    }

    /// Once, not on every tick of a drag. The row clears `muted` on the first
    /// one, and this is what makes the rest of the gesture ask for nothing.
    func testAnUnmutedDisplayIsLeftAlone() {
        XCTAssertEqual(EZVolumeMute.action(percent: 10, muted: false, muteAtZero: true), .leaveAlone)
    }

    // MARK: - Reaching the bottom

    func testZeroMutesWhenTheOptionIsOn() {
        XCTAssertEqual(EZVolumeMute.action(percent: 0, muted: false, muteAtZero: true), .mute)
    }

    /// Off is off. The display goes to zero and stays unmuted, which is what
    /// every build before this one did.
    func testZeroDoesNothingWhenTheOptionIsOff() {
        XCTAssertEqual(EZVolumeMute.action(percent: 0, muted: false, muteAtZero: false), .leaveAlone)
    }

    /// The case that would otherwise loop. A held volume-down key arrives at
    /// zero and keeps arriving, and asking for a mute that is already set is a
    /// DDC exchange per repeat for no change.
    func testAMutedDisplayAtZeroIsNotMutedAgain() {
        XCTAssertEqual(EZVolumeMute.action(percent: 0, muted: true, muteAtZero: true), .leaveAlone)
    }

    /// And with the option off, zero must not unmute either. The old rule was
    /// written as "not at zero, where unmuting would contradict the value being
    /// written", and it still holds.
    func testZeroDoesNotUnmute() {
        XCTAssertEqual(EZVolumeMute.action(percent: 0, muted: true, muteAtZero: false), .leaveAlone)
    }

    // MARK: - Values that should not arrive

    /// Below zero counts as zero rather than as somewhere quieter still. The
    /// percentage is clamped before it gets here, so this is only about what the
    /// rule means: silence is silence.
    func testBelowZeroIsTreatedAsZero() {
        XCTAssertEqual(EZVolumeMute.action(percent: -5, muted: false, muteAtZero: true), .mute)
        XCTAssertEqual(EZVolumeMute.action(percent: -5, muted: true, muteAtZero: true), .leaveAlone)
    }

    func testFullVolumeIsNoDifferentFromAnyOtherAudibleValue() {
        XCTAssertEqual(EZVolumeMute.action(percent: 100, muted: true, muteAtZero: true), .unmute)
        XCTAssertEqual(EZVolumeMute.action(percent: 100, muted: false, muteAtZero: true), .leaveAlone)
    }
}
