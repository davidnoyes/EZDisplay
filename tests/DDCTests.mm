//
//  DDCTests.mm
//  EZDisplay
//
//  Tests for the one part of src/DDC.h that needs no monitor: subscribing to
//  the AV service proxies coming and going.
//
//  That subscription is what keeps a cached service from outliving its proxy.
//  Without it the cache is dropped only on a CoreGraphics reconfiguration, and
//  macOS can tear a proxy down and build a new one without posting one — after
//  which every volume write goes to a dead Mach port and fails.
//

#import <XCTest/XCTest.h>
#import "DDC.h"

@interface DDCProxyWatchTests : XCTestCase
@end

@implementation DDCProxyWatchTests

// IOKit accepts a matching notification for a class with no instances, so this
// holds on a Mac with no external display, which is what CI is.
- (void)testBothProxySubscriptionsAreAccepted
{
    XCTAssertTrue(EZDDCWatchProxies());
}

- (void)testSubscribingAgainKeepsTheFirstSubscription
{
    XCTAssertTrue(EZDDCWatchProxies());
    XCTAssertTrue(EZDDCWatchProxies());
}

@end

@interface DDCAwaitingAnswerTests : XCTestCase
@end

@implementation DDCAwaitingAnswerTests

// The app asks this after every build to decide whether to look again, so an
// empty cache has to say no — or a Mac with no monitor would rebuild its menu
// on a timer until the retries ran out.
- (void)testNothingIsAwaitedOnceTheCachesAreDropped
{
    [EZDisplayAudio invalidateCaches];
    XCTAssertFalse([EZDisplayAudio awaitingAnswer]);
}

// Opening the menu and pressing a volume key both ask this, so with nothing
// awaited it has to stay quiet — or every press on a Mac with no monitor would
// rebuild the menu.
- (void)testLookingAgainWithNothingAwaitedFindsNothing
{
    [EZDisplayAudio invalidateCaches];

    XCTestExpectation *answered = [self expectationWithDescription: @"answered"];
    answered.inverted = YES;
    [EZDisplayAudio lookAgainWhereUnanswered: ^{ [answered fulfill]; }];

    [self waitForExpectations: @[answered] timeout: 0.5];
}

@end
