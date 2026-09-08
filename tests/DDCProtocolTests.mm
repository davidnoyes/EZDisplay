//
//  DDCProtocolTests.mm
//  EZDisplay
//
//  Tests for src/DDCProtocol.h: the bytes EZDisplay puts on a monitor's I2C
//  bus, and what it makes of the bytes that come back.
//
//  These are asserted as literal frames rather than by rebuilding each one from
//  the same helper the implementation uses, which would only prove the code
//  agrees with itself. A checksum seeded a byte wrong still produces a frame
//  that looks like a frame; the display is the only thing that would notice,
//  and by then the bytes have been sent.
//
//  The rejection tests do use a helper to seal their replies, because what they
//  are about is the checks that come after the checksum, and each needs a
//  checksum that passes so the reply reaches them. The literal frames above
//  them are what pins the checksum itself.
//

#import <XCTest/XCTest.h>
#import "DDCProtocol.h"

#include <vector>

/// A reply with the checksum a display would have put on it.
///
/// Takes the first ten bytes and seals them the way the protocol says. The one
/// thing it cannot be used for is testing the checksum, which is why the frames
/// that do that are written out in full.
static std::vector<uint8_t> Sealed(std::vector<uint8_t> reply)
{
    uint8_t chk = 0x50;
    for (size_t i = 0; i + 1 < reply.size(); i++)
        chk ^= reply[i];
    reply[reply.size() - 1] = chk;
    return reply;
}

/// A well-formed reply to a get of `vcp`, for a dial at `current` of `maximum`.
static std::vector<uint8_t> GoodReply(uint8_t vcp, uint16_t current, uint16_t maximum)
{
    return Sealed({0x6E, 0x88, 0x02, 0x00, vcp, 0x00,
                   (uint8_t) (maximum >> 8), (uint8_t) (maximum & 0xFF),
                   (uint8_t) (current >> 8), (uint8_t) (current & 0xFF), 0x00});
}

static EZDDCReading Parse(uint8_t vcp, const std::vector<uint8_t> &reply)
{
    return EZDDCParseReply(vcp, reply.data(), reply.size());
}


#pragma mark - The frames that go out

@interface DDCRequestTests : XCTestCase
@end

@implementation DDCRequestTests

- (void)testAReadRequestIsTheFourByteGetFeatureFrame
{
    // 0x82 is the length byte — the high bit set, plus a body of two. Then the
    // body length, the code, and a checksum seeded with the 7-bit address
    // shifted up: 0x37 << 1 is 0x6E, and 0x6E ^ 0x82 ^ 0x01 ^ 0x62 is 0x8F.
    uint8_t packet[EZDDCReadRequestLength] = {0};
    XCTAssertEqual(EZDDCBuildReadRequest(EZVCPSpeakerVolume, packet),
                   (size_t) EZDDCReadRequestLength);

    const uint8_t expected[] = {0x82, 0x01, 0x62, 0x8F};
    XCTAssertEqual(memcmp(packet, expected, sizeof(expected)), 0);
}

- (void)testAReadRequestForADifferentCodeChangesOnlyTheCodeAndTheChecksum
{
    uint8_t packet[EZDDCReadRequestLength] = {0};
    EZDDCBuildReadRequest(EZVCPAudioMute, packet);

    const uint8_t expected[] = {0x82, 0x01, 0x8D, 0x60};
    XCTAssertEqual(memcmp(packet, expected, sizeof(expected)), 0);
}

- (void)testAWriteRequestSeedsItsChecksumDifferentlyFromARead
{
    // The asymmetry is real and it is the part most easily got wrong. A read
    // seeds with 0x6E alone; a write seeds with 0x6E ^ 0x51, the data address,
    // giving 0x3F. Then 0x3F ^ 0x84 ^ 0x03 ^ 0x62 ^ 0x00 ^ 0x32 is 0xE8.
    //
    // Seeding a write the way a read is seeded would put 0xB9 here, which is a
    // frame the display rejects rather than one it misreads — but silently, and
    // it would read as the monitor refusing the code.
    uint8_t packet[EZDDCWriteRequestLength] = {0};
    XCTAssertEqual(EZDDCBuildWriteRequest(EZVCPSpeakerVolume, 50, packet),
                   (size_t) EZDDCWriteRequestLength);

    const uint8_t expected[] = {0x84, 0x03, 0x62, 0x00, 0x32, 0xE8};
    XCTAssertEqual(memcmp(packet, expected, sizeof(expected)), 0);
}

- (void)testAWriteRequestPutsTheValueOnTheWireBigEndian
{
    // 320 does not fit a byte, and the frame has two for it. Getting the order
    // backwards would ask a display for 0x4001 instead of 0x0140.
    uint8_t packet[EZDDCWriteRequestLength] = {0};
    EZDDCBuildWriteRequest(EZVCPSpeakerVolume, 320, packet);

    const uint8_t expected[] = {0x84, 0x03, 0x62, 0x01, 0x40, 0x9B};
    XCTAssertEqual(memcmp(packet, expected, sizeof(expected)), 0);
}

- (void)testMutingIsWrittenAsOneAndUnmutingAsTwo
{
    uint8_t packet[EZDDCWriteRequestLength] = {0};
    EZDDCBuildWriteRequest(EZVCPAudioMute, EZDDCMuted, packet);

    const uint8_t expected[] = {0x84, 0x03, 0x8D, 0x00, 0x01, 0x34};
    XCTAssertEqual(memcmp(packet, expected, sizeof(expected)), 0);

    // Two, not zero. The code's off state is a value it defines rather than the
    // absence of the on state, and zero means nothing to it.
    XCTAssertEqual(EZDDCUnmuted, 2);
}

@end


#pragma mark - The replies that come back

@interface DDCReplyTests : XCTestCase
@end

@implementation DDCReplyTests

- (void)testAGoodReplyGivesTheCurrentValueAndTheDisplaysOwnMaximum
{
    // Written out rather than sealed by the helper, so this pins the reply
    // checksum too: 0x50 seeds it, and every byte but the last goes in.
    const std::vector<uint8_t> reply = {0x6E, 0x88, 0x02, 0x00, 0x62, 0x00,
                                        0x00, 0x64, 0x00, 0x32, 0x80};
    XCTAssertEqual(Sealed(reply), reply, @"the literal checksum and the helper disagree");

    const EZDDCReading reading = Parse(EZVCPSpeakerVolume, reply);
    XCTAssertTrue(reading.answered());
    XCTAssertEqual(reading.current, 50);
    XCTAssertEqual(reading.maximum, 100);
}

- (void)testTheNullMessagePassesTheChecksumAndIsStillNotAnAnswer
{
    // The case that makes a checksum-only reader wrong. The display answers
    // `6e 80 be 00` and then zeros, and the seed cancels against those three
    // bytes exactly: 0x50 ^ 0x6E is 0x3E, ^ 0x80 is 0xBE, ^ 0xBE is 0x00, and
    // every byte after it is zero. So the trailing zero is the correct checksum
    // and the frame is well formed — carrying no answer at all.
    //
    // AppleSiliconDDC checks the checksum and nothing else, so it reads this as
    // a dial sitting at zero with a range of zero.
    const std::vector<uint8_t> nullMessage = {0x6E, 0x80, 0xBE, 0x00, 0x00, 0x00,
                                              0x00, 0x00, 0x00, 0x00, 0x00};
    XCTAssertEqual(Sealed(nullMessage), nullMessage, @"the null message must pass the checksum");

    XCTAssertFalse(Parse(EZVCPSpeakerVolume, nullMessage).answered());
}

- (void)testAReplyAboutAnotherCodeIsNotAnAnswer
{
    // What catches a read taken before the display settled: the buffer holds
    // the previous exchange, shifted or whole, and its bytes parse into a
    // plausible setting. The echoed code is the only thing that says so.
    XCTAssertFalse(Parse(EZVCPSpeakerVolume, GoodReply(EZVCPBrightness, 50, 100)).answered());
}

- (void)testAnErrorResultIsNotAnAnswer
{
    std::vector<uint8_t> reply = GoodReply(EZVCPSpeakerVolume, 50, 100);
    reply[3] = 0x01;                    // "unsupported VCP code"
    XCTAssertFalse(Parse(EZVCPSpeakerVolume, Sealed(reply)).answered());
}

- (void)testAReplyThatIsNotAFeatureReplyIsNotAnAnswer
{
    std::vector<uint8_t> reply = GoodReply(EZVCPSpeakerVolume, 50, 100);
    reply[2] = 0x03;                    // a set-feature reply, not a get
    XCTAssertFalse(Parse(EZVCPSpeakerVolume, Sealed(reply)).answered());
}

- (void)testABadChecksumIsNotAnAnswer
{
    std::vector<uint8_t> reply = GoodReply(EZVCPSpeakerVolume, 50, 100);
    reply[10] ^= 0xFF;
    XCTAssertFalse(Parse(EZVCPSpeakerVolume, reply).answered());
}

- (void)testAShortBufferIsNotAnAnswer
{
    // The reply length is fixed, so a caller with a smaller buffer has a bug
    // rather than a short reply. Refusing it here is cheaper than reading past
    // the end of it to find out.
    std::vector<uint8_t> reply = GoodReply(EZVCPSpeakerVolume, 50, 100);
    reply.pop_back();
    XCTAssertFalse(Parse(EZVCPSpeakerVolume, reply).answered());
}

- (void)testARejectedReplyCarriesNoValuesAtAll
{
    // Zero rather than whatever the bytes held, so a caller that forgets to
    // check `answered` reads an obvious nothing instead of a plausible setting.
    const EZDDCReading reading = Parse(EZVCPSpeakerVolume, GoodReply(EZVCPBrightness, 50, 100));
    XCTAssertEqual(reading.current, 0);
    XCTAssertEqual(reading.maximum, 0);
}

- (void)testAZeroMaximumIsAnUnimplementedCodeRatherThanAnEmptyRange
{
    // The other way a display says no: a well-formed reply about the right
    // code, published with an empty range.
    const EZDDCReading empty = Parse(EZVCPSpeakerVolume, GoodReply(EZVCPSpeakerVolume, 0, 0));
    XCTAssertTrue(empty.answered(), @"the reply itself is well formed");
    XCTAssertFalse(EZDDCReadingIsSupported(empty));

    XCTAssertTrue(EZDDCReadingIsSupported(Parse(EZVCPSpeakerVolume,
                                                GoodReply(EZVCPSpeakerVolume, 0, 100))),
                  @"a dial at zero with a real range is supported and turned down");
}

- (void)testAReplyThatNeverArrivedIsNotSupported
{
    XCTAssertFalse(EZDDCReadingIsSupported(EZDDCReading()));
}

@end


#pragma mark - What the range cache is allowed to remember

/// The decision `MaximumFor` applies, extracted so it can be asserted.
///
/// It was inline, and a mutation removing the whole guard — reinstating the
/// cache-poisoning bug this file exists to prevent — left every test green,
/// because the surrounding function needs an I2C bus and cannot be reached.
/// Nothing about the decision needs one.
@interface DDCRangeCacheTests : XCTestCase
@end

@implementation DDCRangeCacheTests

static EZDDCReading NullMessageReading(void)
{
    const std::vector<uint8_t> nullMessage = {0x6E, 0x80, 0xBE, 0x00, 0x00, 0x00,
                                              0x00, 0x00, 0x00, 0x00, 0x00};
    return Parse(EZVCPSpeakerVolume, nullMessage);
}

static EZDDCReading RefusedReading(void)
{
    std::vector<uint8_t> refused = GoodReply(EZVCPSpeakerVolume, 50, 100);
    refused[3] = 0x01;
    return Parse(EZVCPSpeakerVolume, Sealed(refused));
}

- (void)testTheDisplaysOwnAnswerIsRememberedAtOnce
{
    // Both directions of a settled answer, from a cache holding nothing.
    XCTAssertEqual(EZDDCRangeToRemember(EZDDCRangeUnknown,
                                        Parse(EZVCPSpeakerVolume,
                                              GoodReply(EZVCPSpeakerVolume, 27, 100))),
                   100);
    XCTAssertEqual(EZDDCRangeToRemember(EZDDCRangeUnknown, RefusedReading()), 0);

    XCTAssertTrue(EZDDCRangeIsSettled(100));
    XCTAssertTrue(EZDDCRangeIsSettled(0), @"a display that said no has settled it");
}

- (void)testOneFailedReadSettlesNothing
{
    // The bug. A single null message cached its zero, and the control was gone
    // for the life of the process on a monitor that has it.
    const int after = EZDDCRangeToRemember(EZDDCRangeUnknown, NullMessageReading());
    XCTAssertEqual(after, EZDDCRangeUnconfirmed);
    XCTAssertFalse(EZDDCRangeIsSettled(after),
                   @"an unconfirmed entry must send the next call back to the display");

    // A read that never arrived at all is the same kind of nothing.
    XCTAssertFalse(EZDDCRangeIsSettled(EZDDCRangeToRemember(EZDDCRangeUnknown,
                                                            EZDDCReading())));
}

- (void)testASecondFailedReadSettlesItAsAbsent
{
    // The other end of the trade. Retrying for ever would be its own defect: a
    // display whose way of saying "no such code" is the null message would then
    // be re-probed on every call, at four attempts and a third of a second
    // each, for as long as the app runs. Twice is enough — the reference panel
    // sends one null in about a dozen exchanges, and a read is already four
    // attempts, so agreeing twice by chance takes eight in a row.
    const int once = EZDDCRangeToRemember(EZDDCRangeUnknown, NullMessageReading());
    const int twice = EZDDCRangeToRemember(once, NullMessageReading());

    XCTAssertEqual(twice, 0);
    XCTAssertTrue(EZDDCRangeIsSettled(twice));
}

- (void)testAnAnswerAfterAFailedReadIsBelievedRatherThanHeldAgainstIt
{
    // What makes the failure self-healing: one bad exchange does not make the
    // display prove itself twice.
    const int once = EZDDCRangeToRemember(EZDDCRangeUnknown, NullMessageReading());
    XCTAssertEqual(EZDDCRangeToRemember(once,
                                        Parse(EZVCPSpeakerVolume,
                                              GoodReply(EZVCPSpeakerVolume, 27, 100))),
                   100);
}

- (void)testAWellFormedEmptyRangeIsAbsentOnTheFirstReadRatherThanTheSecond
{
    // Not a failed exchange: the display answered, and its answer was a dial
    // that cannot move. Making it repeat itself would cost an exchange to
    // confirm something already said.
    const EZDDCReading empty = Parse(EZVCPSpeakerVolume, GoodReply(EZVCPSpeakerVolume, 0, 0));
    XCTAssertEqual(EZDDCRangeToRemember(EZDDCRangeUnknown, empty), 0);
}

@end


#pragma mark - Frames this parser was actually handed

/// Bytes captured off the bus, not composed here.
///
/// Every other fixture in this file is built by `GoodReply`, which seals it with
/// the same checksum routine the parser checks — so a wrong seed would agree
/// with itself and the tests would pass. These three came out of a real
/// exchange with a PHL 34M2C8600 over DisplayPort, printed by a temporary trace
/// in `ReadVCP`, and they are the independent check that costs nothing to keep.
@interface DDCCapturedReplyTests : XCTestCase
@end

@implementation DDCCapturedReplyTests

- (void)testACapturedVolumeReplyParsesToWhatTheMonitorWasShowing
{
    // The monitor's own on-screen display read 27 at the time of capture, on a
    // dial its menu runs from 0 to 100.
    const std::vector<uint8_t> captured = {0x6E, 0x88, 0x02, 0x00, 0x62, 0x00,
                                           0x00, 0x64, 0x00, 0x1B, 0xA9};
    const EZDDCReading reading = Parse(EZVCPSpeakerVolume, captured);

    XCTAssertTrue(reading.answered(), @"a real reply must survive every check");
    XCTAssertEqual(reading.maximum, 100);
    XCTAssertEqual(reading.current, 27);
    XCTAssertEqual(captured.back(), Sealed(captured).back(),
                   @"the checksum this code computes must match the one the display sent");
}

- (void)testACapturedMuteReplyParsesToUnmuted
{
    // Answering with a maximum of 2, which is why the availability gate lets
    // this panel's mute through. See the note on `muteAvailableForDisplay:`.
    const std::vector<uint8_t> captured = {0x6E, 0x88, 0x02, 0x00, 0x8D, 0x00,
                                           0x00, 0x02, 0x00, 0x02, 0x39};
    const EZDDCReading reading = Parse(EZVCPAudioMute, captured);

    XCTAssertTrue(reading.answered());
    XCTAssertEqual(reading.maximum, 2);
    XCTAssertEqual(reading.current, EZDDCUnmuted);
    XCTAssertEqual(captured.back(), Sealed(captured).back());
}

- (void)testTheCapturedNullMessageIsTheOneThisParserExpects
{
    // The frame that caused the bug. Captured from the same monitor, on the
    // volume code, one exchange after it answered that code properly — which is
    // how the "not ready" reading was arrived at rather than guessed.
    const std::vector<uint8_t> captured = {0x6E, 0x80, 0xBE, 0x00, 0x00, 0x00,
                                           0x00, 0x00, 0x00, 0x00, 0x00};
    XCTAssertEqual(Parse(EZVCPSpeakerVolume, captured).outcome, EZDDCReplyNotReady);
    XCTAssertEqual(captured.back(), Sealed(captured).back(),
                   @"it passes the checksum, which is what makes it dangerous");
}

@end


#pragma mark - Whether the exchange is worth repeating

@interface DDCRetryTests : XCTestCase
@end

@implementation DDCRetryTests

- (void)testADefiniteNoIsNotWorthRepeating
{
    // The display answering, in the one way that means "no such code": a proper
    // get-feature reply about the code that was asked for, carrying an error.
    // Asking four more times would add most of half a second and change nothing.
    std::vector<uint8_t> refused = GoodReply(EZVCPSpeakerVolume, 50, 100);
    refused[3] = 0x01;
    XCTAssertEqual(Parse(EZVCPSpeakerVolume, Sealed(refused)).outcome, EZDDCReplyUnsupported);
}

- (void)testTheNullMessageIsNotReadyRatherThanARefusal
{
    // Read as a refusal until the hardware said otherwise. Over twelve runs
    // against a PHL 34M2C8600 this frame came back twice: once for the mute
    // code, and once for the volume code — which the same monitor answered with
    // a range of 100 and a dial at 27 on the other eleven. A code cannot be
    // absent on one exchange and present on the next, so the null message is
    // the display saying "nothing for you right now", not "no such code".
    //
    // Reading it as a refusal is what made a control vanish: one of these
    // landed, the capability cached zero, and the monitor had no volume row for
    // the life of the process.
    const std::vector<uint8_t> nullMessage = {0x6E, 0x80, 0xBE, 0x00, 0x00, 0x00,
                                              0x00, 0x00, 0x00, 0x00, 0x00};
    XCTAssertEqual(Parse(EZVCPSpeakerVolume, nullMessage).outcome, EZDDCReplyNotReady);
    XCTAssertFalse(EZDDCReadingIsDefinite(Parse(EZVCPSpeakerVolume, nullMessage)),
                   @"a display that is not ready has told you nothing to remember");
}

- (void)testOnlyTheDisplaysOwnAnswerIsWorthRemembering
{
    // What separates knowledge from the absence of it. A capability cache that
    // stores a failed exchange turns one bad read into a permanent verdict, so
    // only these two outcomes may be written to it.
    XCTAssertTrue(EZDDCReadingIsDefinite(Parse(EZVCPSpeakerVolume,
                                               GoodReply(EZVCPSpeakerVolume, 50, 100))));

    std::vector<uint8_t> refused = GoodReply(EZVCPSpeakerVolume, 50, 100);
    refused[3] = 0x01;
    XCTAssertTrue(EZDDCReadingIsDefinite(Parse(EZVCPSpeakerVolume, Sealed(refused))),
                  @"a display that says it has no such code will say so again");

    // Every way an exchange can fail, none of which is the display's verdict.
    XCTAssertFalse(EZDDCReadingIsDefinite(EZDDCReading()));

    std::vector<uint8_t> corrupt = GoodReply(EZVCPSpeakerVolume, 50, 100);
    corrupt[10] ^= 0xFF;
    XCTAssertFalse(EZDDCReadingIsDefinite(Parse(EZVCPSpeakerVolume, corrupt)));

    XCTAssertFalse(EZDDCReadingIsDefinite(Parse(EZVCPSpeakerVolume,
                                                GoodReply(EZVCPBrightness, 50, 100))));
}

- (void)testATransportFaultIsWorthRepeating
{
    // A reply about another code is the settle time having been too short, so
    // the bytes are the previous exchange's. Trying again is exactly the fix.
    XCTAssertEqual(Parse(EZVCPSpeakerVolume, GoodReply(EZVCPBrightness, 50, 100)).outcome,
                   EZDDCReplyGarbled);

    std::vector<uint8_t> corrupt = GoodReply(EZVCPSpeakerVolume, 50, 100);
    corrupt[10] ^= 0xFF;
    XCTAssertEqual(Parse(EZVCPSpeakerVolume, corrupt).outcome, EZDDCReplyGarbled);

    // No reply at all is the same kind of nothing.
    XCTAssertEqual(EZDDCReading().outcome, EZDDCReplyGarbled);
}

- (void)testAnUnrecognisedOpcodeIsWorthRepeating
{
    // Only the null message's exact shape counts as a refusal. Any other opcode
    // is a buffer that got here somehow, and guessing "the display means no"
    // from it would turn one bad read into a control that vanishes.
    std::vector<uint8_t> reply = GoodReply(EZVCPSpeakerVolume, 50, 100);
    reply[2] = 0x03;
    XCTAssertEqual(Parse(EZVCPSpeakerVolume, Sealed(reply)).outcome, EZDDCReplyGarbled);
}

@end


#pragma mark - The dial the display published

@interface DDCScaleTests : XCTestCase
@end

@implementation DDCScaleTests

- (void)testAPercentageMapsThroughTheDisplaysOwnMaximum
{
    // Panels report 64, 100, and 255. Writing a percentage straight through
    // would sit a third of the way up the 255-step dial and off the end of the
    // 64-step one.
    XCTAssertEqual(EZDDCRawFromPercent(50, 64), 32);
    XCTAssertEqual(EZDDCRawFromPercent(50, 100), 50);
    XCTAssertEqual(EZDDCRawFromPercent(50, 255), 128);

    XCTAssertEqual(EZDDCPercentFromRaw(32, 64), 50);
    XCTAssertEqual(EZDDCPercentFromRaw(128, 255), 50);
}

- (void)testTheEndsOfTheDialAreExact
{
    // Neither end may be reached by rounding. Nine tenths of full volume when
    // the slider is at the top is the kind of wrong nobody reports and everyone
    // notices.
    XCTAssertEqual(EZDDCRawFromPercent(0, 64), 0);
    XCTAssertEqual(EZDDCRawFromPercent(100, 64), 64);
    XCTAssertEqual(EZDDCPercentFromRaw(0, 64), 0);
    XCTAssertEqual(EZDDCPercentFromRaw(64, 64), 100);
}

- (void)testAValueOutsideTheRangeIsClampedRatherThanRefused
{
    XCTAssertEqual(EZDDCRawFromPercent(-10, 100), 0);
    XCTAssertEqual(EZDDCRawFromPercent(150, 100), 100);
    XCTAssertEqual(EZDDCPercentFromRaw(-1, 100), 0);
    XCTAssertEqual(EZDDCPercentFromRaw(200, 100), 100);
}

- (void)testADialWithNoRangeHasNoPercentage
{
    // Reachable only through the unsupported reading above, which the callers
    // gate on — but the arithmetic would divide by zero, so it answers rather
    // than trusting them.
    XCTAssertEqual(EZDDCPercentFromRaw(0, 0), -1);
    XCTAssertEqual(EZDDCRawFromPercent(50, 0), 0);
}

@end


#pragma mark - Whether a write landed

@interface DDCWriteVerificationTests : XCTestCase
@end

@implementation DDCWriteVerificationTests

- (void)testADialThatDidNotMoveDidNotTakeTheWrite
{
    // The Philips 34M2C8600 on brightness: the bus takes the bytes, the write
    // reports success, and the firmware discards it because macOS owns that
    // dial. Only the read-back says so.
    XCTAssertFalse(EZDDCWriteTookEffect(80, 50, 100));
}

- (void)testADialThatLandedWhereItWasAskedTookTheWrite
{
    XCTAssertTrue(EZDDCWriteTookEffect(80, 80, 100));
}

- (void)testADisplayThatSnapsToItsOwnStepStillTookTheWrite
{
    // A display whose volume steps in twos answers 52 to a write of 51. Exact
    // equality would call that a refusal and put the slider back, which is the
    // one thing worse than the value being two out.
    XCTAssertTrue(EZDDCWriteTookEffect(51, 52, 100));
}

- (void)testWritingTheValueAlreadySetTookTheWrite
{
    // Nothing to move, so not moving is the right outcome. Reporting failure
    // here would make every second press of a key at the end of the dial look
    // like a refusal.
    XCTAssertTrue(EZDDCWriteTookEffect(80, 80, 100));
}

- (void)testADialThatMovedSomewhereElseDidNotTakeTheWrite
{
    // The write that started all this: 11 was asked to become 20 and the dial
    // went to 0. Movement alone called that applied and the command exited 0,
    // so the one check standing between a bad write and a report of success
    // waved it through.
    XCTAssertFalse(EZDDCWriteTookEffect(20, 0, 100));
}

- (void)testTheToleranceScalesWithTheDialRatherThanTheNumber
{
    // Three out of 255 is within a step of a dial that fine; three out of 20
    // is fifteen percent of the range and a different setting entirely.
    XCTAssertTrue(EZDDCWriteTookEffect(200, 203, 255));
    XCTAssertFalse(EZDDCWriteTookEffect(10, 13, 20));
}

- (void)testTheToleranceIsExactlyATwentiethOfTheRange
{
    // The pair above says the tolerance scales. It does not say how wide it is:
    // any divisor from about 7 to about 85 satisfies both, so widening the one
    // number that decides whether a write which went somewhere else counts as
    // applied left every test green. These two pin it — on a range of 100 the
    // widest accepted miss is 5, and 6 is a different setting.
    XCTAssertTrue(EZDDCWriteTookEffect(80, 85, 100));
    XCTAssertFalse(EZDDCWriteTookEffect(80, 86, 100));
}

- (void)testACodeWhoseValuesAreNamesNeedsAnExactAnswer
{
    // Mute is 1 and unmute is 2. They are a two-value range, so the tolerance
    // rounds to zero and near enough stops being good enough — which is right,
    // because landing on the neighbor of "muted" is landing on "not muted".
    XCTAssertTrue(EZDDCWriteTookEffect(EZDDCMuted, EZDDCMuted, 2));
    XCTAssertFalse(EZDDCWriteTookEffect(EZDDCMuted, EZDDCUnmuted, 2));
}

@end

#pragma mark - The floor under a volume write

@interface DDCVolumeFloorTests : XCTestCase
@end

@implementation DDCVolumeFloorTests

- (void)testAQuietSettingNeverRoundsDownIntoAMute
{
    // Rounding is to nearest, so this only bites on a dial coarse enough that
    // the bottom percentages have nowhere to land: 1% of 32 is 0.32, and a 0
    // written to the volume code is a mute rather than a quiet setting.
    XCTAssertEqual(EZDDCRawFromPercent(1, 32), 0);
    XCTAssertEqual(EZDDCVolumeRawFromPercent(1, 32), 1);

    // A 64-step dial rounds 1% up to 1 on its own, so the floor changes
    // nothing there — which is the point of putting it under rounding rather
    // than in place of it.
    XCTAssertEqual(EZDDCVolumeRawFromPercent(1, 64), EZDDCRawFromPercent(1, 64));
}

- (void)testAskingForSilenceStillReachesZero
{
    // The floor is under rounding, not under the user. Someone who asks for 0
    // gets 0, because that is what the control on screen says it does.
    XCTAssertEqual(EZDDCVolumeRawFromPercent(0, 64), 0);
    XCTAssertEqual(EZDDCVolumeRawFromPercent(0, 100), 0);
}

- (void)testEveryOtherPercentageIsUnchanged
{
    for (int percent = 2; percent <= 100; percent++)
        XCTAssertEqual(EZDDCVolumeRawFromPercent(percent, 100),
                       EZDDCRawFromPercent(percent, 100),
                       @"%d%% should be untouched by the floor", percent);
}

- (void)testARangeThatIsNotARangeStaysRefused
{
    XCTAssertEqual(EZDDCVolumeRawFromPercent(50, 0), EZDDCRawFromPercent(50, 0));
}

@end
