//
//  DDCProtocol.mm
//  EZDisplay
//

#include "DDCProtocol.h"

#include <string.h>

// The DDC/CI host's 7-bit I2C address, and the register inside the display that
// a frame is written to and read from. IOAVServiceWriteI2C takes both as
// arguments, so neither appears in the buffer — but the checksum is defined
// over the whole exchange, which is why they seed it below.
static const uint8_t kHostAddress = 0x37;
static const uint8_t kDataAddress = 0x51;

// The seeds stand in for the address bytes a frame would carry on a plain I2C
// bus. They are not symmetric, and the asymmetry is AppleSiliconDDC's rather
// than the specification's: DDC/CI puts both addresses into a get's checksum,
// and that library seeds a get with the host address alone. Its way is what is
// proven against Apple silicon, so it is what this follows.
static const uint8_t kReadSeed  = kHostAddress << 1;
static const uint8_t kWriteSeed = (kHostAddress << 1) ^ kDataAddress;

// A reply seeds with the host's virtual address instead, which is fixed.
static const uint8_t kReplySeed = 0x50;

enum {
    kOpcodeGetFeatureReply = 0x02,
    kResultNoError         = 0x00,
};

// Offsets into a reply. The two values are big-endian pairs.
enum {
    kReplyBodyLength = 1,
    kReplyOpcode     = 2,
    kReplyResult     = 3,
    kReplyVCP        = 4,
    kReplyMaximum    = 6,
    kReplyCurrent    = 8,
};

// The null message a display sends for a code it does not implement, in the two
// bytes that identify it: a zero-length body and 0xBE where an opcode goes.
enum {
    kNullBodyLength = 0x80,
    kNullOpcode     = 0xBE,
};

static uint8_t Checksum(uint8_t seed, const uint8_t *bytes, size_t count)
{
    uint8_t chk = seed;
    for (size_t i = 0; i < count; i++)
        chk ^= bytes[i];
    return chk;
}

// Both requests have the same shape: a length byte with its high bit set, the
// body length, the body, and a checksum over everything before it.
static size_t BuildRequest(uint8_t seed, const uint8_t *body, size_t bodyLength,
                           uint8_t *packet)
{
    packet[0] = (uint8_t) (0x80 | (bodyLength + 1));
    packet[1] = (uint8_t) bodyLength;
    memcpy(packet + 2, body, bodyLength);

    const size_t length = bodyLength + 3;
    packet[length - 1] = Checksum(seed, packet, length - 1);
    return length;
}

size_t EZDDCBuildReadRequest(uint8_t vcp, uint8_t *packet)
{
    const uint8_t body[] = {vcp};
    return BuildRequest(kReadSeed, body, sizeof(body), packet);
}

size_t EZDDCBuildWriteRequest(uint8_t vcp, uint16_t value, uint8_t *packet)
{
    const uint8_t body[] = {vcp, (uint8_t) (value >> 8), (uint8_t) (value & 0xFF)};
    return BuildRequest(kWriteSeed, body, sizeof(body), packet);
}

EZDDCReading EZDDCParseReply(uint8_t vcp, const uint8_t *reply, size_t length)
{
    EZDDCReading reading;

    // Every failure leaves the values at zero rather than filling them in from
    // bytes that did not pass, so a caller that skips the outcome reads an
    // obvious nothing instead of a plausible setting.
    //
    // Nothing arrived, or what arrived is not a frame. Both are the transport,
    // so both are worth another go.
    if (length != EZDDCReplyLength)
        return reading;
    if (Checksum(kReplySeed, reply, length - 1) != reply[length - 1])
        return reading;

    // The null message, taken before the opcode check so it is read as itself
    // rather than as a frame that failed one. Its checksum is valid, and its
    // VCP byte is zero rather than the code that was asked for, so neither of
    // the checks below would tell it from a garbled read.
    if (reply[kReplyBodyLength] == kNullBodyLength && reply[kReplyOpcode] == kNullOpcode)
    {
        reading.outcome = EZDDCReplyNotReady;
        return reading;
    }

    // Any other opcode is a buffer that reached here somehow. Reading "the
    // display means no" into it would turn one bad exchange into a control that
    // disappears, so it is a fault to retry.
    if (reply[kReplyOpcode] != kOpcodeGetFeatureReply)
        return reading;

    // A reply about another code is a read taken before the display settled,
    // which returns the previous exchange's bytes.
    if (reply[kReplyVCP] != vcp)
        return reading;

    // Well formed, about the right code, and carrying an error: the display
    // answering that it has no such code.
    if (reply[kReplyResult] != kResultNoError)
    {
        reading.outcome = EZDDCReplyUnsupported;
        return reading;
    }

    reading.outcome = EZDDCReplyValid;
    reading.maximum = (uint16_t) ((reply[kReplyMaximum] << 8) | reply[kReplyMaximum + 1]);
    reading.current = (uint16_t) ((reply[kReplyCurrent] << 8) | reply[kReplyCurrent + 1]);
    return reading;
}

bool EZDDCReadingIsSupported(const EZDDCReading &reading)
{
    return reading.answered() && reading.maximum > 0;
}

bool EZDDCReadingIsDefinite(const EZDDCReading &reading)
{
    return reading.outcome == EZDDCReplyValid
        || reading.outcome == EZDDCReplyUnsupported;
}

int EZDDCRangeToRemember(int cached, const EZDDCReading &reading)
{
    // The display answered, either way, so nothing older matters.
    if (EZDDCReadingIsDefinite(reading))
        return EZDDCReadingIsSupported(reading) ? reading.maximum : 0;

    // It did not, and this is the second time. Two failed reads in a row are
    // what a display that answers this way every time looks like.
    if (cached == EZDDCRangeUnconfirmed)
        return 0;

    return EZDDCRangeUnconfirmed;
}

int EZDDCRawFromPercent(int percent, int maximum)
{
    if (maximum <= 0)
        return 0;
    // The ends are taken before the arithmetic so neither can be reached by
    // rounding: a slider at the top has to mean the top of the display's range.
    if (percent <= 0)
        return 0;
    if (percent >= 100)
        return maximum;
    return (percent * maximum + 50) / 100;
}

int EZDDCPercentFromRaw(int raw, int maximum)
{
    if (maximum <= 0)
        return -1;
    if (raw <= 0)
        return 0;
    if (raw >= maximum)
        return 100;
    return (raw * 100 + maximum / 2) / maximum;
}

bool EZDDCWriteTookEffect(int wanted, int after, int maximum)
{
    // A twentieth of the range, so the tolerance means the same thing on a
    // 64-step dial as on a 255-step one. Integer division floors it, which is
    // what a two-value code such as mute needs: no tolerance at all.
    const int tolerance = maximum > 0 ? maximum / 20 : 0;
    const int missedBy  = after > wanted ? after - wanted : wanted - after;
    return missedBy <= tolerance;
}

int EZDDCVolumeRawFromPercent(int percent, int maximum)
{
    const int raw = EZDDCRawFromPercent(percent, maximum);

    // Only rounding is floored. A caller that asked for silence gets it.
    if (raw == 0 && percent > 0 && maximum > 0)
        return 1;
    return raw;
}
