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
