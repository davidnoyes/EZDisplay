//
//  NightShiftTests.mm
//  EZDisplay
//
//  Tests for how src/CoreBrightness.mm reads the three Night Shift states out
//  of the daemon's dials.
//
//  The reading the menu ticks and the command line reports hangs off one
//  question that the mode and the tint alone cannot answer: with a schedule
//  running and the tint on, is that the schedule's window, or the **Turn on
//  until tomorrow** override sitting on top of it? The daemon's override value
//  says which. The numbers are measured against the real daemon, not taken
//  from a header: 4 after turning the tint on, 3 after turning it off inside
//  the window, and 0 once a mode change or the window closing clears it.
//

#import <XCTest/XCTest.h>
#import "CoreBrightness.h"

static const NSInteger kNoOverride  = 0;
static const NSInteger kOverrideOff = 3;
static const NSInteger kOverrideOn  = 4;

@interface NightShiftStateTests : XCTestCase
@end

@implementation NightShiftStateTests

- (void)testNoScheduleAndNoTintIsOff
{
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeOff enabled: NO override: kNoOverride],
                   EZNightShiftOff);
}

- (void)testTintWithNoScheduleIsOnUntilTomorrow
{
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeOff enabled: YES override: kOverrideOn],
                   EZNightShiftUntilTomorrow);
}

- (void)testTintWithNoScheduleIsOnUntilTomorrowWhenTheOverrideCannotBeRead
{
    // A release that stops reporting the override must not lose the state the
    // tint and the mode already settle between them.
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeOff enabled: YES override: kNoOverride],
                   EZNightShiftUntilTomorrow);
}

- (void)testScheduleOutsideItsWindowIsScheduled
{
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeSunset enabled: NO override: kNoOverride],
                   EZNightShiftScheduled);
}

- (void)testScheduleInsideItsWindowIsScheduled
{
    // The tint is on because the window covers this minute, and nobody asked
    // for it, so the schedule is what is in force.
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeSunset enabled: YES override: kNoOverride],
                   EZNightShiftScheduled);
}

- (void)testOverrideOnTopOfASunsetScheduleIsOnUntilTomorrow
{
    // The regression. Turning the tint on keeps the schedule underneath, as
    // the System Settings checkbox does, so the mode alone reads as Scheduled
    // and the menu would tick the wrong item.
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeSunset enabled: YES override: kOverrideOn],
                   EZNightShiftUntilTomorrow);
}

- (void)testOverrideOnTopOfACustomScheduleIsOnUntilTomorrow
{
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeCustom enabled: YES override: kOverrideOn],
                   EZNightShiftUntilTomorrow);
}

- (void)testOverrideTurningTheTintOffInsideTheWindowIsScheduled
{
    // Off until the schedule next changes, which only System Settings and
    // Control Center can set. The menu has no item for it, and Scheduled is
    // the one that comes back on its own.
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeSunset enabled: NO override: kOverrideOff],
                   EZNightShiftScheduled);
}

- (void)testOverrideWithTheTintOffIsNotOnUntilTomorrow
{
    // The two disagree only if one of them is stale. The tint is what the user
    // can see, so a menu saying "on" over a screen with no tint is the worse
    // mistake.
    XCTAssertEqual([EZNightShift stateForMode: EZNightShiftModeSunset enabled: NO override: kOverrideOn],
                   EZNightShiftScheduled);
}

@end
