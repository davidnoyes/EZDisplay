//
//  MediaKeysTests.mm
//  EZDisplay
//
//  Tests for src/MediaKeys.h: what EZDisplay makes of a media key press, and
//  when it is entitled to take one.
//
//  Most of the `data1` values here are built by `Data1` rather than captured,
//  which on its own would prove only that the builder and the decoder agree
//  about a layout they might both have wrong. `CapturedMediaKeyTests` is what
//  stops that being circular: seven literals recorded off this machine's own
//  keyboard, pinned the way `DDCProtocolTests` pins literal DDC frames. The
//  built values then cover the combinations a keyboard cannot easily be made
//  to produce, and the literals hold the layout still.
//

#import <XCTest/XCTest.h>
#import "MediaKeys.h"

// The key codes from IOKit's ev_keymap.h, repeated rather than imported so a
// test that starts failing says which number changed.
enum {
    kSoundUp   = 0,
    kSoundDown = 1,
    kMute      = 7,
    kPlay      = 16,   ///< A media key this project does not act on.
};

// Subtype 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS. Anything else sharing
// NX_SYSDEFINED is a different kind of event that happens to be packed the
// same way.
static const int kAuxControlButtons = 8;

/// A `data1` for one key, in one state.
static int64_t Data1(int keyCode, bool down, bool repeated)
{
    const int state = down ? 0x0A : 0x0B;
    const int flags = (state << 8) | (repeated ? 1 : 0);
    return ((int64_t) keyCode << 16) | flags;
}


#pragma mark - Decoding

@interface MediaKeyDecodeTests : XCTestCase
@end

@implementation MediaKeyDecodeTests

- (void)testTheThreeKeysThisProjectActsOn
{
    XCTAssertEqual(EZDecodeMediaKey(kAuxControlButtons, Data1(kSoundUp, true, false)).key,
                   EZMediaKeyVolumeUp);
    XCTAssertEqual(EZDecodeMediaKey(kAuxControlButtons, Data1(kSoundDown, true, false)).key,
                   EZMediaKeyVolumeDown);
    XCTAssertEqual(EZDecodeMediaKey(kAuxControlButtons, Data1(kMute, true, false)).key,
                   EZMediaKeyMute);
}

- (void)testAnotherMediaKeyIsNotOneOfOurs
{
    XCTAssertEqual(EZDecodeMediaKey(kAuxControlButtons, Data1(kPlay, true, false)).key,
                   EZMediaKeyNone);
}

- (void)testAnotherSubtypeIsNotAKeyAtAll
{
    // The bits say volume up. The subtype says this event is about something
    // else, and the subtype is what decides.
    XCTAssertEqual(EZDecodeMediaKey(7, Data1(kSoundUp, true, false)).key, EZMediaKeyNone);
    XCTAssertEqual(EZDecodeMediaKey(0, Data1(kSoundUp, true, false)).key, EZMediaKeyNone);
}

- (void)testDownAndUpAreToldApart
{
    XCTAssertTrue(EZDecodeMediaKey(kAuxControlButtons, Data1(kMute, true, false)).pressed);
    XCTAssertFalse(EZDecodeMediaKey(kAuxControlButtons, Data1(kMute, false, false)).pressed);
}

- (void)testAHeldKeySaysSo
{
    XCTAssertTrue(EZDecodeMediaKey(kAuxControlButtons, Data1(kSoundUp, true, true)).repeated);
    XCTAssertFalse(EZDecodeMediaKey(kAuxControlButtons, Data1(kSoundUp, true, false)).repeated);
}

@end


#pragma mark - Acting

@interface MediaKeyActionTests : XCTestCase
@end

@implementation MediaKeyActionTests

- (void)testAPressActs
{
    XCTAssertTrue(EZMediaKeyShouldAct(EZDecodeMediaKey(kAuxControlButtons,
                                                       Data1(kSoundUp, true, false))));
}

- (void)testAReleaseDoesNot
{
    XCTAssertFalse(EZMediaKeyShouldAct(EZDecodeMediaKey(kAuxControlButtons,
                                                        Data1(kSoundUp, false, false))));
}

- (void)testAHeldVolumeKeyKeepsStepping
{
    XCTAssertTrue(EZMediaKeyShouldAct(EZDecodeMediaKey(kAuxControlButtons,
                                                       Data1(kSoundDown, true, true))));
}

- (void)testAHeldMuteKeyTogglesOnce
{
    XCTAssertTrue(EZMediaKeyShouldAct(EZDecodeMediaKey(kAuxControlButtons,
                                                       Data1(kMute, true, false))));
    XCTAssertFalse(EZMediaKeyShouldAct(EZDecodeMediaKey(kAuxControlButtons,
                                                        Data1(kMute, true, true))),
                   @"holding mute would otherwise leave the state up to the timing");
}

- (void)testAnEventThatIsNotOneOfOursNeverActs
{
    XCTAssertFalse(EZMediaKeyShouldAct(EZDecodeMediaKey(kAuxControlButtons,
                                                        Data1(kPlay, true, false))));
}

@end


#pragma mark - Interception

@interface MediaKeyInterceptionTests : XCTestCase
@end

@implementation MediaKeyInterceptionTests

- (void)testTheKeysAreTakenOnlyWhenMacOSHasNothingToMoveAndThisAppHas
{
    XCTAssertTrue(EZMediaKeyShouldIntercept(EZMediaKeyVolumeUp, false, true));
}

- (void)testAnOutputMacOSCanSetKeepsItsKeys
{
    // Headphones, or the built-in speakers. Taking the keys here would break
    // volume control on a machine where it was working.
    XCTAssertFalse(EZMediaKeyShouldIntercept(EZMediaKeyVolumeUp, true, true));
}

- (void)testNoDisplayToDriveMeansNoReasonToTakeThem
{
    XCTAssertFalse(EZMediaKeyShouldIntercept(EZMediaKeyVolumeUp, false, false));
}

- (void)testAKeyThisProjectDoesNotActOnIsAlwaysPassedOn
{
    XCTAssertFalse(EZMediaKeyShouldIntercept(EZMediaKeyNone, false, true));
}

- (void)testAKeyIsTakenEvenWhenItsPressWillNotMoveAnything
{
    // Interception is decided on the key, not on whether the press acts. Mute
    // at 100% proves it: nothing here asks what the press will do, so a key
    // whose press changes nothing is still taken rather than handed to macOS.
    //
    // The tap asks this once, for the first press of a hold. What the repeats
    // and the release do is `EZMediaKeyTakeEvent`'s answer, and
    // `MediaKeyHoldTests` is where that is asked.
    XCTAssertTrue(EZMediaKeyShouldIntercept(EZMediaKeyMute, false, true));
}

@end


#pragma mark - Stepping

@interface VolumeKeyStepTests : XCTestCase
@end

@implementation VolumeKeyStepTests

- (void)testAKeyMovesAboutASixteenthOfTheRange
{
    const int up = EZVolumeAfterKey(50, EZMediaKeyVolumeUp);
    XCTAssertEqual(up, 56);
    XCTAssertEqual(EZVolumeAfterKey(50, EZMediaKeyVolumeDown), 44);
}

- (void)testSixteenPressesCrossTheWholeRange
{
    int percent = 0;
    for (int i = 0; i < 16; i++)
        percent = EZVolumeAfterKey(percent, EZMediaKeyVolumeUp);
    XCTAssertEqual(percent, 100);

    for (int i = 0; i < 16; i++)
        percent = EZVolumeAfterKey(percent, EZMediaKeyVolumeDown);
    XCTAssertEqual(percent, 0);
}

- (void)testAValueBetweenStepsMovesToTheNextOneRatherThanPastIt
{
    // What a display sitting where its own buttons left it looks like. Rounding
    // to the nearest step first would send 47 up to 56 and down to 44, missing
    // 50 in both directions.
    XCTAssertEqual(EZVolumeAfterKey(47, EZMediaKeyVolumeUp), 50);
    XCTAssertEqual(EZVolumeAfterKey(47, EZMediaKeyVolumeDown), 44);
}

- (void)testTheEndsHold
{
    XCTAssertEqual(EZVolumeAfterKey(100, EZMediaKeyVolumeUp), 100);
    XCTAssertEqual(EZVolumeAfterKey(0, EZMediaKeyVolumeDown), 0);
}

- (void)testOutOfRangeInputComesBackInRange
{
    XCTAssertEqual(EZVolumeAfterKey(140, EZMediaKeyVolumeDown), 94);
    XCTAssertEqual(EZVolumeAfterKey(-20, EZMediaKeyVolumeUp), 6);
}

- (void)testMuteIsNotAStep
{
    XCTAssertEqual(EZVolumeAfterKey(37, EZMediaKeyMute), 37);
    XCTAssertEqual(EZVolumeAfterKey(37, EZMediaKeyNone), 37);
}

@end


#pragma mark - The layout, against real events

/// Seven `data1` values recorded from this machine's own keyboard through a
/// listen-only tap: on 2026-09-08 one press each of volume up, volume down and
/// mute on an internal Apple keyboard, and on 2026-09-09 a mute key held down
/// long enough to autorepeat.
///
/// These are the only values in this file that were not built by `Data1`, and
/// they are the reason the rest can be. Every other decode test asserts that
/// the decoder agrees with a builder written from the same description of the
/// layout; if that description were wrong, both would be wrong together and
/// every test would still pass. A literal recorded off the wire cannot agree
/// with a mistake.
@interface CapturedMediaKeyTests : XCTestCase
@end

@implementation CapturedMediaKeyTests

- (void)testVolumeUpAsTheKeyboardSendsIt
{
    const EZMediaKeyPress down = EZDecodeMediaKey(8, 0x0000000000000A00);
    XCTAssertEqual(down.key, EZMediaKeyVolumeUp);
    XCTAssertTrue(down.pressed);
    XCTAssertFalse(down.repeated);

    const EZMediaKeyPress up = EZDecodeMediaKey(8, 0x0000000000000B00);
    XCTAssertEqual(up.key, EZMediaKeyVolumeUp);
    XCTAssertFalse(up.pressed);
}

- (void)testVolumeDownAsTheKeyboardSendsIt
{
    const EZMediaKeyPress down = EZDecodeMediaKey(8, 0x0000000000010A00);
    XCTAssertEqual(down.key, EZMediaKeyVolumeDown);
    XCTAssertTrue(down.pressed);

    const EZMediaKeyPress up = EZDecodeMediaKey(8, 0x0000000000010B00);
    XCTAssertEqual(up.key, EZMediaKeyVolumeDown);
    XCTAssertFalse(up.pressed);
}

- (void)testMuteAsTheKeyboardSendsIt
{
    const EZMediaKeyPress down = EZDecodeMediaKey(8, 0x0000000000070A00);
    XCTAssertEqual(down.key, EZMediaKeyMute);
    XCTAssertTrue(down.pressed);

    const EZMediaKeyPress up = EZDecodeMediaKey(8, 0x0000000000070B00);
    XCTAssertEqual(up.key, EZMediaKeyMute);
    XCTAssertFalse(up.pressed);
}

/// A key held down, which is the one thing the other six captures cannot show.
/// They are all first presses and releases, so every one of them has the repeat
/// bit clear: which bit a keyboard actually sets when it autorepeats was, until
/// this was recorded, pinned only by `Data1` and the decoder making the same
/// assumption. Believing the wrong bit would have passed every test in the file
/// and swallowed a held key without stepping the volume.
- (void)testAHeldKeyAsTheKeyboardSendsIt
{
    const EZMediaKeyPress repeat = EZDecodeMediaKey(8, 0x0000000000070A01);
    XCTAssertEqual(repeat.key, EZMediaKeyMute);
    XCTAssertTrue(repeat.pressed);
    XCTAssertTrue(repeat.repeated);
}

/// The captured values and the builder describe the same layout. This is the
/// assertion that lets the rest of the file use `Data1` without apology.
- (void)testTheBuilderAgreesWithTheKeyboard
{
    XCTAssertEqual(Data1(kSoundUp,   true,  false), 0x0000000000000A00);
    XCTAssertEqual(Data1(kSoundUp,   false, false), 0x0000000000000B00);
    XCTAssertEqual(Data1(kSoundDown, true,  false), 0x0000000000010A00);
    XCTAssertEqual(Data1(kSoundDown, false, false), 0x0000000000010B00);
    XCTAssertEqual(Data1(kMute,      true,  false), 0x0000000000070A00);
    XCTAssertEqual(Data1(kMute,      false, false), 0x0000000000070B00);
    XCTAssertEqual(Data1(kMute,      true,  true),  0x0000000000070A01);
}

@end


#pragma mark - Swallowing a press and its release together

/// `EZMediaKeyTakeEvent` exists because the gate can change its mind between a
/// press and its release. These fix what happens when it does.
@interface MediaKeyHoldTests : XCTestCase
@end

@implementation MediaKeyHoldTests

- (void)testATakenPressIsSwallowedAndRemembered
{
    int held = 0;
    const EZMediaKeyPress down = EZDecodeMediaKey(kAuxControlButtons,
                                                  Data1(kSoundUp, true, false));
    XCTAssertTrue(EZMediaKeyTakeEvent(down, true, &held));
    XCTAssertEqual(held, 1 << (int) EZMediaKeyVolumeUp);
}

- (void)testARefusedPressIsPassedOnAndNotRemembered
{
    int held = 0;
    const EZMediaKeyPress down = EZDecodeMediaKey(kAuxControlButtons,
                                                  Data1(kSoundUp, true, false));
    XCTAssertFalse(EZMediaKeyTakeEvent(down, false, &held));
    XCTAssertEqual(held, 0);
}

/// The whole reason the function exists: the gate says no by the time the key
/// comes up, and the release is swallowed anyway because the press was taken.
- (void)testAReleaseFollowsItsPressEvenWhenTheGateHasChangedItsMind
{
    int held = 0;
    const EZMediaKeyPress down = EZDecodeMediaKey(kAuxControlButtons,
                                                  Data1(kSoundUp, true, false));
    const EZMediaKeyPress up   = EZDecodeMediaKey(kAuxControlButtons,
                                                  Data1(kSoundUp, false, false));

    XCTAssertTrue(EZMediaKeyTakeEvent(down, true, &held));
    // Headphones went in while the key was down. The monitor being unplugged
    // instead is the same test: both halves of the gate reach this function as
    // the one `intercept` bool, so there is nothing here that could tell a
    // `systemHasVolume` that turned true from a `hasTarget` that turned false.
    XCTAssertTrue(EZMediaKeyTakeEvent(up, false, &held));
    XCTAssertEqual(held, 0);
}

/// And the other way round: the press was passed on, so the release must be
/// too, however inviting the gate now looks.
- (void)testAReleaseIsPassedOnWhenItsPressWas
{
    int held = 0;
    const EZMediaKeyPress down = EZDecodeMediaKey(kAuxControlButtons,
                                                  Data1(kSoundUp, true, false));
    const EZMediaKeyPress up   = EZDecodeMediaKey(kAuxControlButtons,
                                                  Data1(kSoundUp, false, false));

    XCTAssertFalse(EZMediaKeyTakeEvent(down, false, &held));
    XCTAssertFalse(EZMediaKeyTakeEvent(up, true, &held));
    XCTAssertEqual(held, 0);
}

- (void)testAReleaseWithNoPressBehindItIsNeverSwallowed
{
    int held = 0;
    const EZMediaKeyPress up = EZDecodeMediaKey(kAuxControlButtons,
                                                Data1(kMute, false, false));
    XCTAssertFalse(EZMediaKeyTakeEvent(up, true, &held));
}

- (void)testEveryRepeatOfAHeldKeyIsSwallowed
{
    int held = 0;
    const EZMediaKeyPress down   = EZDecodeMediaKey(kAuxControlButtons,
                                                    Data1(kSoundDown, true, false));
    const EZMediaKeyPress repeat = EZDecodeMediaKey(kAuxControlButtons,
                                                    Data1(kSoundDown, true, true));

    XCTAssertTrue(EZMediaKeyTakeEvent(down, true, &held));
    XCTAssertTrue(EZMediaKeyTakeEvent(repeat, true, &held));
    XCTAssertTrue(EZMediaKeyTakeEvent(repeat, true, &held));
}

/// The same change of mind as above, but arriving mid-hold rather than at the
/// release. A repeat is part of the hold that started it, so it goes the way
/// the first press went; handing macOS a repeat it has no press for is the
/// same half-event, only in the other direction.
- (void)testAHoldStaysWithWhoeverTookItsFirstPress
{
    int held = 0;
    const EZMediaKeyPress down   = EZDecodeMediaKey(kAuxControlButtons,
                                                    Data1(kSoundUp, true, false));
    const EZMediaKeyPress repeat = EZDecodeMediaKey(kAuxControlButtons,
                                                    Data1(kSoundUp, true, true));
    const EZMediaKeyPress up     = EZDecodeMediaKey(kAuxControlButtons,
                                                    Data1(kSoundUp, false, false));

    XCTAssertTrue(EZMediaKeyTakeEvent(down, true, &held));
    XCTAssertTrue(EZMediaKeyTakeEvent(repeat, false, &held));
    XCTAssertTrue(EZMediaKeyTakeEvent(up, false, &held));
    XCTAssertEqual(held, 0);
}

/// And a hold macOS started stays with macOS, however inviting the gate looks
/// by the time the key repeats.
- (void)testAHoldMacOSStartedIsNotTakenMidway
{
    int held = 0;
    const EZMediaKeyPress down   = EZDecodeMediaKey(kAuxControlButtons,
                                                    Data1(kSoundUp, true, false));
    const EZMediaKeyPress repeat = EZDecodeMediaKey(kAuxControlButtons,
                                                    Data1(kSoundUp, true, true));

    XCTAssertFalse(EZMediaKeyTakeEvent(down, false, &held));
    XCTAssertFalse(EZMediaKeyTakeEvent(repeat, true, &held));
    XCTAssertEqual(held, 0);
}

/// Two keys can be down at once, and one going up must not release the other.
- (void)testTwoKeysAreHeldSeparately
{
    int held = 0;
    const EZMediaKeyPress volumeDown = EZDecodeMediaKey(kAuxControlButtons,
                                                        Data1(kSoundUp, true, false));
    const EZMediaKeyPress muteDown   = EZDecodeMediaKey(kAuxControlButtons,
                                                        Data1(kMute, true, false));
    const EZMediaKeyPress muteUp     = EZDecodeMediaKey(kAuxControlButtons,
                                                        Data1(kMute, false, false));
    const EZMediaKeyPress volumeUp   = EZDecodeMediaKey(kAuxControlButtons,
                                                        Data1(kSoundUp, false, false));

    XCTAssertTrue(EZMediaKeyTakeEvent(volumeDown, true, &held));
    XCTAssertTrue(EZMediaKeyTakeEvent(muteDown, true, &held));
    XCTAssertTrue(EZMediaKeyTakeEvent(muteUp, false, &held));
    XCTAssertNotEqual(held, 0);   // the volume key is still down
    XCTAssertTrue(EZMediaKeyTakeEvent(volumeUp, false, &held));
    XCTAssertEqual(held, 0);
}

- (void)testAnEventThatIsNotAKeyIsNeverTaken
{
    int held = 0;
    const EZMediaKeyPress other = EZDecodeMediaKey(kAuxControlButtons,
                                                   Data1(kPlay, true, false));
    XCTAssertFalse(EZMediaKeyTakeEvent(other, true, &held));
    XCTAssertEqual(held, 0);

    // The line above goes through the decoder, which never reports a press of
    // a key it did not recognize: an unknown code comes back as `None` with
    // the flags left alone, so it always looks like a release and the release
    // path answers it. Built by hand, so the press path has to answer for
    // itself rather than being covered by an accident of the decoder.
    EZMediaKeyPress pressed;
    pressed.pressed = true;
    XCTAssertEqual(pressed.key, EZMediaKeyNone);
    XCTAssertFalse(EZMediaKeyTakeEvent(pressed, true, &held));
    XCTAssertEqual(held, 0);
}

@end


#pragma mark - Starting the watcher

/// Four combinations, and the one that matters is a tap that already exists
/// with a grant that has just come back. The version of this that lived inline
/// in `startWithHandler:` answered that one by returning, so the keys stayed
/// dead until the app was restarted, and no test could reach the mistake.
@interface VolumeKeysStartTests : XCTestCase
@end

@implementation VolumeKeysStartTests

- (void)testWithNoGrantThereIsNothingToDo
{
    XCTAssertEqual(EZVolumeKeysStartAction(false, false), EZVolumeKeysStartNothing);
}

/// Revoked while a tap was running. Switching it back on would not work
/// without the grant, and asking is what makes the answer honest.
- (void)testAGrantTakenAwayLeavesTheTapAlone
{
    XCTAssertEqual(EZVolumeKeysStartAction(false, true), EZVolumeKeysStartNothing);
}

- (void)testTheFirstStartBuildsATap
{
    XCTAssertEqual(EZVolumeKeysStartAction(true, false), EZVolumeKeysStartCreate);
}

/// The grant coming back. Building a second tap would leave the first sitting
/// dead at the head of the chain, still first in line for every event.
- (void)testAGrantComingBackSwitchesTheOldTapOn
{
    XCTAssertEqual(EZVolumeKeysStartAction(true, true), EZVolumeKeysStartEnable);
}

@end


#pragma mark - Whether a press reaches the display

/// A volume key press normally goes out only when it moves the dial. Mute is
/// the state that breaks that, because muting does not move the dial: the value
/// the key would write is already the value on the display, and skipping the
/// write leaves a person pressing volume up at a silent monitor.
@interface VolumeRowWriteTests : XCTestCase
@end

@implementation VolumeRowWriteTests

- (void)testAPressThatMovesTheDialIsWritten
{
    XCTAssertTrue(EZVolumeRowNeedsWrite(50, 56, false));
    XCTAssertTrue(EZVolumeRowNeedsWrite(50, 44, false));
}

/// Muted only ever adds presses. Asserted rather than left to the short circuit,
/// because a rule written the other way round — muted decides, and the dial only
/// matters when it does not — would pass every other test here.
- (void)testAMutedRowStillWritesAPressThatMovesTheDial
{
    XCTAssertTrue(EZVolumeRowNeedsWrite(50, 56, true));
    XCTAssertTrue(EZVolumeRowNeedsWrite(50, 44, true));
}

/// Both rails. Holding volume up at 100 should put nothing on the bus.
- (void)testAPressAtTheRailIsNotWritten
{
    XCTAssertFalse(EZVolumeRowNeedsWrite(100, 100, false));
    XCTAssertFalse(EZVolumeRowNeedsWrite(0, 0, false));
}

/// The case this exists for. A display muted at full volume answers volume up
/// with the value it is already at, so the one press that was meant to bring
/// the sound back was the one press that did nothing.
- (void)testAMutedRowIsWrittenEvenWhenTheDialDoesNotMove
{
    XCTAssertTrue(EZVolumeRowNeedsWrite(100, 100, true));
}

/// Muted and already at zero, asked to go down. There is nothing to unmute
/// towards, so this stays the no-op it is when the sound is on.
- (void)testAMutedRowAtZeroIsNotWrittenByGoingDown
{
    XCTAssertFalse(EZVolumeRowNeedsWrite(0, 0, true));
}

@end


#pragma mark - What the feedback panel shows

/// The bar is sixteen chiclets because the keys move in sixteen steps, so a
/// press has to move it by exactly one. Anything that rounded differently from
/// `EZVolumeAfterKey` would show a press doing nothing, or two.
@interface VolumeChicletTests : XCTestCase
@end

@implementation VolumeChicletTests

/// The assertion the whole shape rests on: every value a volume key can leave
/// behind fills one more chiclet than the value below it. Written as the ladder
/// rather than as a formula, so agreeing with `EZVolumeAfterKey` by copying its
/// arithmetic is not enough to pass.
- (void)testEveryStepTheKeysCanReachLightsOneMoreChiclet
{
    int percent = 0;
    for (int expected = 0; expected <= kEZVolumeChiclets; expected++)
    {
        XCTAssertEqual(EZVolumeChicletsLit(percent, false), expected, @"at %d%%", percent);
        percent = EZVolumeAfterKey(percent, EZMediaKeyVolumeUp);
    }
    XCTAssertEqual(percent, 100);
}

/// A display sitting between two steps, because its own buttons put it there.
/// It rounds to the nearer chiclet rather than truncating, so 47 reads as half
/// rather than as one short of it.
- (void)testAValueBetweenStepsRoundsToTheNearerChiclet
{
    XCTAssertEqual(EZVolumeChicletsLit(47, false), 8);
    XCTAssertEqual(EZVolumeChicletsLit(3, false), 0);
    XCTAssertEqual(EZVolumeChicletsLit(97, false), 16);
}

/// Muted is a state of its own rather than a volume of zero, so the bar empties
/// whatever the display's dial says. Leaving it where it was would say the
/// sound is still coming out.
- (void)testAMutedDisplayLightsNothing
{
    XCTAssertEqual(EZVolumeChicletsLit(75, true), 0);
    XCTAssertEqual(EZVolumeChicletsLit(100, true), 0);
}

/// A DDC read can hand back anything, and a chiclet count outside the bar
/// would be drawn as one.
- (void)testAPercentageOutsideTheRangeIsClamped
{
    XCTAssertEqual(EZVolumeChicletsLit(-5, false), 0);
    XCTAssertEqual(EZVolumeChicletsLit(150, false), 16);
}

@end


#pragma mark - When the feedback sound plays

/// The timing is the whole of the native feel here, and it is not the obvious
/// one. Volume clicks when the key comes back up, so holding it ratchets the
/// bar in silence and clicks once; mute clicks on the way down.
@interface VolumeFeedbackSoundTests : XCTestCase
@end

@implementation VolumeFeedbackSoundTests

static bool PlaysFor(int keyCode, bool down, bool repeated, bool enabled)
{
    const EZMediaKeyPress press = EZDecodeMediaKey(kAuxControlButtons,
                                                   Data1(keyCode, down, repeated));
    return EZShouldPlayVolumeFeedback(press, enabled);
}

/// Sixteen clicks for one hold is the bug this prevents, and it is the reason
/// the release was chosen over the press.
- (void)testAHeldVolumeKeyClicksOnceWhenItComesUp
{
    XCTAssertFalse(PlaysFor(kSoundUp, true,  false, true));
    XCTAssertFalse(PlaysFor(kSoundUp, true,  true,  true));
    XCTAssertFalse(PlaysFor(kSoundUp, true,  true,  true));
    XCTAssertTrue (PlaysFor(kSoundUp, false, false, true));
}

- (void)testVolumeDownClicksOnTheSameEdge
{
    XCTAssertFalse(PlaysFor(kSoundDown, true,  false, true));
    XCTAssertTrue (PlaysFor(kSoundDown, false, false, true));
}

/// Mute is the exception, and it goes the other way: the click lands on the
/// press, and its repeats are silent because the mute itself acts once.
- (void)testMuteClicksOnThePressAndNotOnItsRepeats
{
    XCTAssertTrue (PlaysFor(kMute, true,  false, true));
    XCTAssertFalse(PlaysFor(kMute, true,  true,  true));
    XCTAssertFalse(PlaysFor(kMute, false, false, true));
}

/// System Settings › Sound › Play feedback when volume is changed. Off means
/// off for every key and every edge, which is the point of asking.
- (void)testNothingClicksWhenTheSettingIsOff
{
    XCTAssertFalse(PlaysFor(kSoundUp,   false, false, false));
    XCTAssertFalse(PlaysFor(kSoundDown, false, false, false));
    XCTAssertFalse(PlaysFor(kMute,      true,  false, false));
}

- (void)testAnEventThatIsNotAKeyIsSilent
{
    XCTAssertFalse(PlaysFor(kPlay, true,  false, true));
    XCTAssertFalse(PlaysFor(kPlay, false, false, true));
}

@end
