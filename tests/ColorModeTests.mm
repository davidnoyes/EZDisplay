//
//  ColorModeTests.mm
//  EZDisplay
//
//  Tests for the ambiguity judgment in src/ColorMode.mm.
//
//  A display is matched to its AV interface on manufacturer and product alone,
//  because the serial number is not reported consistently enough to break a
//  tie. That leaves one question the whole color-mode and HDR feature set
//  hangs off: when more than one AV interface reports the same product, is that
//  two monitors, or one monitor the DCP has exposed more than once?
//
//  Getting it wrong in one direction attributes one monitor's color mode to
//  another. Getting it wrong in the other direction reports nothing at all for
//  a perfectly ordinary single display — which is the bug these tests were
//  written for: a 34" Philips appears as two DCPAVVideoInterfaceProxy services
//  with byte-identical product attributes, and the whole color mode UI
//  vanished because of it.
//

#import <XCTest/XCTest.h>
#import "ColorMode.h"

@interface ColorModeAmbiguityTests : XCTestCase
@end

@implementation ColorModeAmbiguityTests

- (void)testOneInterfaceForOneDisplayIsNotAmbiguous
{
    XCTAssertFalse([EZColorModes matchIsAmbiguousWithInterfaces:1 sharingDisplays:1]);
}

- (void)testTwoInterfacesForOneDisplayAreTheSameMonitorTwice
{
    // The regression. The DCP exposes a proxy per stream, so a single monitor
    // can present two interfaces carrying identical product attributes. With
    // only one display reporting that product there is nothing to confuse it
    // with, so the match is safe to use.
    XCTAssertFalse([EZColorModes matchIsAmbiguousWithInterfaces:2 sharingDisplays:1]);
}

- (void)testManyInterfacesForOneDisplayAreStillOneMonitor
{
    XCTAssertFalse([EZColorModes matchIsAmbiguousWithInterfaces:4 sharingDisplays:1]);
}

- (void)testTwoInterfacesForTwoIdenticalDisplaysAreAmbiguous
{
    // Two of the same monitor. Either interface could belong to either, and
    // picking one would silently report the wrong display's color mode.
    XCTAssertTrue([EZColorModes matchIsAmbiguousWithInterfaces:2 sharingDisplays:2]);
}

- (void)testOneInterfaceForTwoIdenticalDisplaysIsNotAmbiguous
{
    // Only one interface was matched, so there is no choice to get wrong.
    // Whether it is the right one is a separate question this does not answer,
    // but reporting nothing here would lose a display that has an answer.
    XCTAssertFalse([EZColorModes matchIsAmbiguousWithInterfaces:1 sharingDisplays:2]);
}

- (void)testNoInterfacesIsNotAmbiguous
{
    // Nothing matched. The caller returns NULL on its own account; ambiguity
    // does not enter into it.
    XCTAssertFalse([EZColorModes matchIsAmbiguousWithInterfaces:0 sharingDisplays:1]);
    XCTAssertFalse([EZColorModes matchIsAmbiguousWithInterfaces:0 sharingDisplays:3]);
}

- (void)testDisplayCountIsNeverZeroInPracticeButMustNotCrash
{
    // CGGetOnlineDisplayList can fail, which reports zero displays. Treating
    // that as ambiguous would disable color mode on the strength of an
    // unrelated error, so it is not.
    XCTAssertFalse([EZColorModes matchIsAmbiguousWithInterfaces:2 sharingDisplays:0]);
}

@end


//  Which of several matched interfaces to read from.
//
//  Recognizing that two proxies are one monitor is only half of it: they are
//  not interchangeable. Both carry the same product attributes and the same
//  color and timing elements, but only one is attached to the live link, and
//  the other answers GetLinkData with kIOReturnNoDevice. Taking whichever the
//  iterator yields first is a coin toss that, on the test display, lands on the
//  dead one — which reads as the display having no color mode at all while
//  everything built from the element dictionaries carries on working.

@interface ColorModeInterfaceChoiceTests : XCTestCase
@end

@implementation ColorModeInterfaceChoiceTests

- (void)testNothingMatchedHasNoChoiceToMake
{
    XCTAssertEqual([EZColorModes preferredMatchIndexWithLiveness:(@[])], NSNotFound);
}

- (void)testASingleLiveInterfaceIsChosen
{
    XCTAssertEqual([EZColorModes preferredMatchIndexWithLiveness:(@[@YES])], 0UL);
}

- (void)testTheLiveInterfaceIsChosenOverAnEarlierDeadOne
{
    // The regression. The dead proxy comes first on the test display.
    XCTAssertEqual([EZColorModes preferredMatchIndexWithLiveness:(@[@NO, @YES])], 1UL);
}

- (void)testTheFirstLiveInterfaceWinsWhenSeveralAre
{
    XCTAssertEqual([EZColorModes preferredMatchIndexWithLiveness:(@[@NO, @NO, @YES, @YES])], 2UL);
}

- (void)testAnEarlierLiveInterfaceIsNotDisplacedByALaterDeadOne
{
    XCTAssertEqual([EZColorModes preferredMatchIndexWithLiveness:(@[@YES, @NO])], 0UL);
}

- (void)testNoLiveInterfaceFallsBackToTheFirstMatch
{
    // A sleeping display has no live link, and still has a product name and a
    // timing list worth reading. Reporting nothing would lose both.
    XCTAssertEqual([EZColorModes preferredMatchIndexWithLiveness:(@[@NO])], 0UL);
    XCTAssertEqual([EZColorModes preferredMatchIndexWithLiveness:(@[@NO, @NO])], 0UL);
}

@end


//  Choosing an interface when the display's port is known.
//
//  Product attributes identify a *model*, so two of the same monitor cannot be
//  told apart by them and the code used to fail closed, reporting no color
//  mode for either. The registry says which port each display is attached to,
//  and the proxies for a port carry that node in their own path, so a display
//  can be paired to its own interfaces directly. Two identical monitors are on
//  two different ports, which is the whole answer.
//
//  Port beats product, and port beats liveness across ports: an interface on
//  another port belongs to another monitor, and a live one there is still the
//  wrong display. Liveness only orders the candidates within the right port.

@interface ColorModePortMatchTests : XCTestCase
@end

@implementation ColorModePortMatchTests

- (void)testNothingMatchedHasNoChoiceToMake
{
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[])
                                                  liveness:(@[])
                                           sharingDisplays:1], NSNotFound);
}

- (void)testTheInterfaceOnTheDisplaysOwnPortWins
{
    // Two identical monitors, two interfaces, one each. Before the port was
    // consulted this was the ambiguous case and both displays lost color mode.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @YES])
                                                  liveness:(@[@YES, @YES])
                                           sharingDisplays:2], 1UL);
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@YES, @NO])
                                                  liveness:(@[@YES, @YES])
                                           sharingDisplays:2], 0UL);
}

- (void)testALiveInterfaceOnAnotherPortIsNeverChosen
{
    // The other port is another monitor. Liveness does not make it ours, and
    // choosing it would report a second display's color mode as this one's.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @YES])
                                                  liveness:(@[@YES, @NO])
                                           sharingDisplays:2], 1UL);
}

- (void)testLivenessStillOrdersInterfacesOnTheSamePort
{
    // One monitor, several proxies on its port, only one attached to the link.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@YES, @YES])
                                                  liveness:(@[@NO, @YES])
                                           sharingDisplays:1], 1UL);
}

- (void)testAnUnknownPortFallsBackToTheProductRuleAndItsFailClosed
{
    // No port information: every flag is NO. One monitor is still fine…
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @NO])
                                                  liveness:(@[@NO, @YES])
                                           sharingDisplays:1], 1UL);
    // …and two identical ones still fail closed rather than guess.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @NO])
                                                  liveness:(@[@YES, @YES])
                                           sharingDisplays:2], NSNotFound);
}

- (void)testAPortThatMatchesNoInterfaceFallsBackRatherThanReportingNothing
{
    // The port was read but no proxy carries it — an unexpected registry shape.
    // Falling back is what keeps a working single display working.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO])
                                                  liveness:(@[@YES])
                                           sharingDisplays:1], 0UL);
}

- (void)testASleepingDisplayOnItsOwnPortIsStillChosen
{
    // No live link anywhere on the port, but the product name and timing list
    // are still worth reading.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @YES, @YES])
                                                  liveness:(@[@YES, @NO, @NO])
                                           sharingDisplays:2], 1UL);
}

- (void)testTheReportedShapeOfTheBugTwoIdenticalMonitorsTwoProxiesEach
{
    // What the reported failure actually looks like, rather than a reduction of
    // it: two identical monitors showing two proxies each, and this display's
    // pair is not contiguous. Every other test here uses three entries or fewer,
    // so none of them would catch an implementation that only walked a
    // contiguous run of on-port interfaces.
    //
    // Interfaces 1 and 3 carry this display's port; 3 is the live one.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @YES, @NO, @YES])
                                                  liveness:(@[@YES, @NO, @NO, @YES])
                                           sharingDisplays:2], 3UL);

    // The same four proxies asked about the *other* monitor: 0 and 2 carry the
    // port now, and 0 is the live one. Only the port flags moved, and the answer
    // has to move with them — which is the whole point of consulting the port.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@YES, @NO, @YES, @NO])
                                                  liveness:(@[@YES, @NO, @NO, @YES])
                                           sharingDisplays:2], 0UL);
}

- (void)testThreeIdenticalMonitorsAreStillToldApartByPort
{
    // Two of a kind is the case that was reported; nothing about the rule is
    // limited to two, and this says so.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @NO, @YES])
                                                  liveness:(@[@YES, @YES, @YES])
                                           sharingDisplays:3], 2UL);
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @YES, @NO])
                                                  liveness:(@[@YES, @YES, @YES])
                                           sharingDisplays:3], 1UL);
    // With no port to go on, three of a kind fails closed exactly as two do.
    XCTAssertEqual([EZColorModes preferredMatchIndexOnPort:(@[@NO, @NO, @NO])
                                                  liveness:(@[@YES, @YES, @YES])
                                           sharingDisplays:3], NSNotFound);
}

@end


//  Which modes belong in the list offered for the current timing.
//
//  The display's own element list says nothing about HDR per timing — the test
//  Philips advertises the same PQ elements at all sixty of its timings, 640 ×
//  480 included — so a list built straight from it invites the user to apply an
//  HDR mode the system has already ruled out. That was the inaccurate "HDR
//  compatible" assessment, and applying one of those modes is what produced
//  oversaturated color.
//
//  The carve-out matters as much as the rule. Dropping the mode the link is
//  actually running would leave a list that contradicts itself and, worse, hide
//  the way back off the row the user is stuck on.

@interface ColorModeOfferTests : XCTestCase
@end

@implementation ColorModeOfferTests

- (void)testAnSDRModeIsAlwaysOffered
{
    // Nothing about HDR availability bears on a mode that does not use it.
    XCTAssertTrue([EZColorModes shouldOfferMode:NO hdrAvailable:YES isCurrent:NO]);
    XCTAssertTrue([EZColorModes shouldOfferMode:NO hdrAvailable:NO  isCurrent:NO]);
    XCTAssertTrue([EZColorModes shouldOfferMode:NO hdrAvailable:YES isCurrent:YES]);
    XCTAssertTrue([EZColorModes shouldOfferMode:NO hdrAvailable:NO  isCurrent:YES]);
}

- (void)testAnHDRModeIsOfferedWhereHDRIsAvailable
{
    XCTAssertTrue([EZColorModes shouldOfferMode:YES hdrAvailable:YES isCurrent:NO]);
    XCTAssertTrue([EZColorModes shouldOfferMode:YES hdrAvailable:YES isCurrent:YES]);
}

- (void)testAnHDRModeIsDroppedWhereHDRIsNot
{
    // The whole point of the change: the system has ruled HDR out at this
    // timing, so offering the mode would be the old inaccurate assessment back
    // in a different form.
    XCTAssertFalse([EZColorModes shouldOfferMode:YES hdrAvailable:NO isCurrent:NO]);
}

- (void)testTheRunningModeSurvivesEvenWhenHDRIsUnavailable
{
    // The carve-out. A list that omits the row the link is on contradicts
    // itself, and hiding that row would hide the way back off it.
    XCTAssertTrue([EZColorModes shouldOfferMode:YES hdrAvailable:NO isCurrent:YES]);
}

@end


//  Whether applying a color mode has to move macOS's HDR mode first.
//
//  The bug this answers: with HDR off, picking the HDR color mode gave wrong
//  colors and left the HDR checkbox unticked; with HDR on, picking the SDR mode
//  did the same the other way. A color mode is the wire format alone, and the
//  transfer function it carries is not the wire format's to choose — it belongs
//  to the HDR mode, which is what the compositor renders. Move one and not the
//  other and the cable declares PQ while the compositor emits plain gamma.
//
//  Three call sites hang off this one judgment — the apply, its rollback when
//  the color write does not take, and the revert twenty seconds later — so it
//  is one function rather than three inline comparisons that can drift apart.

@interface ColorModeHDRCouplingTests : XCTestCase
@end

@implementation ColorModeHDRCouplingTests

- (void)testAModeThatWantsTheOtherHDRStateMovesIt
{
    // Both directions, because both were reported and they are not symmetric in
    // the code: one turns HDR on, the other takes it away.
    XCTAssertTrue([EZColorModes shouldChangeHDRTo:YES from:NO  hdrAvailable:YES]);
    XCTAssertTrue([EZColorModes shouldChangeHDRTo:NO  from:YES hdrAvailable:YES]);
}

- (void)testAModeAlreadyInTheRightHDRStateLeavesItAlone
{
    // Picking a different wire format within one HDR state — say 10-bit YCbCr
    // 4:2:2 while HDR stays on — must not blank the screen for an HDR
    // transition that changes nothing.
    XCTAssertFalse([EZColorModes shouldChangeHDRTo:YES from:YES hdrAvailable:YES]);
    XCTAssertFalse([EZColorModes shouldChangeHDRTo:NO  from:NO  hdrAvailable:YES]);
}

- (void)testNothingIsMovedWhereHDRIsUnavailable
{
    // Availability wins over the disagreement rather than being overridden by
    // it. There is nothing to move, so the caller must refuse the change
    // outright — writing the wire format alone here is the original bug — and
    // must not then try to put back an HDR state it never took away.
    XCTAssertFalse([EZColorModes shouldChangeHDRTo:YES from:NO  hdrAvailable:NO]);
    XCTAssertFalse([EZColorModes shouldChangeHDRTo:NO  from:YES hdrAvailable:NO]);
    XCTAssertFalse([EZColorModes shouldChangeHDRTo:YES from:YES hdrAvailable:NO]);
    XCTAssertFalse([EZColorModes shouldChangeHDRTo:NO  from:NO  hdrAvailable:NO]);
}

@end
