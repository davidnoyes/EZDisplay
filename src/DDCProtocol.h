//
//  DDCProtocol.h
//  EZDisplay
//
//  The DDC/CI wire format, as pure functions over bytes.
//
//  Everything that decides what to put on the I2C bus, and what a reply means,
//  lives here where a test can exercise it. `src/DDC.h` is the half that cannot
//  be tested: finding the display's service and handing these bytes to
//  IOAVServiceWriteI2C.
//
//  The split is not tidiness. This is the one part of EZDisplay that writes to
//  a monitor's firmware, and a frame built wrong is not a wrong answer on
//  screen — it is bytes a display was never asked to interpret. The frames
//  below are therefore asserted byte for byte against known-good captures
//  rather than left to be checked by whether the monitor seems happy.
//
//  Modeled on AppleSiliconDDC, read in full on 2026-09-08, because it is the
//  library with the most exposure on Apple silicon. Where it departs from the
//  DDC/CI specification the departure is marked, and where this file adds a
//  check the library does not make that is marked too.
//

#pragma once

#include <stdint.h>
#include <stddef.h>

/// The MCCS codes this project touches, and the only ones it writes.
///
/// Standard codes only is a standing constraint rather than a default: a
/// vendor-specific code means something different on every panel, and the one
/// thing a wrong write can damage is the display itself. Adding to this list is
/// a decision to be taken deliberately, not a line to be slipped in.
enum {
    EZVCPBrightness    = 0x10,  ///< Read only here — see DisplayServices.h.
    EZVCPSpeakerVolume = 0x62,
    EZVCPAudioMute     = 0x8D,
};

/// The two values `EZVCPAudioMute` takes. Not a boolean: the code's off state
/// is 2 rather than 0, and 0 is not a value it defines.
enum {
    EZDDCMuted   = 1,
    EZDDCUnmuted = 2,
};

enum {
    EZDDCReadRequestLength  = 4,
    EZDDCWriteRequestLength = 6,
    EZDDCReplyLength        = 11,
};

/// Builds the "get VCP feature" request for `vcp` into `packet`, which must have
/// room for `EZDDCReadRequestLength` bytes. Returns how many it wrote.
size_t EZDDCBuildReadRequest(uint8_t vcp, uint8_t *packet);

/// Builds the "set VCP feature" request into `packet`, which must have room for
/// `EZDDCWriteRequestLength` bytes. Returns how many it wrote.
///
/// The value goes on the wire big-endian across two bytes, whatever its size,
/// because the frame has two bytes for it either way.
size_t EZDDCBuildWriteRequest(uint8_t vcp, uint16_t value, uint8_t *packet);

/// How a reply came out, which is also whether the exchange is worth repeating.
///
/// The distinction is not academic. Every exchange costs about 90 ms with the
/// settle times the transport needs, and retrying four times over a code the
/// display has just clearly said it does not have would put half a second into
/// each availability check.
enum EZDDCReplyOutcome {
    /// Nothing usable arrived: no reply, a bad checksum, or a reply about
    /// another code. The last is a read taken before the display had settled,
    /// which returns the previous exchange's bytes — so all three are transport
    /// faults, and all three are worth trying again.
    EZDDCReplyGarbled,

    /// The null message: a well-formed frame carrying nothing, which is the
    /// display saying it has no answer ready. Not a refusal — the same monitor
    /// sends this for a code it answers properly on the next exchange — so it
    /// is worth trying again, and worth remembering nothing about.
    EZDDCReplyNotReady,

    /// The display answered, and the answer is that it has no such code. A
    /// definite reply, so repeating it would only be slower.
    EZDDCReplyUnsupported,

    EZDDCReplyValid,
};

/// What a display said when asked for one code.
///
/// A reply that failed any check leaves both values at zero rather than at
/// something plausible.
struct EZDDCReading {
    EZDDCReplyOutcome outcome = EZDDCReplyGarbled;
    uint16_t          current = 0;
    uint16_t          maximum = 0;

    bool answered() const { return outcome == EZDDCReplyValid; }
};

/// Reads an `EZDDCReplyLength`-byte reply to a get of `vcp`.
///
/// Four checks, where AppleSiliconDDC makes one. The checksum alone is not
/// enough, and the reason is specific: the null message a display sends for a
/// code it does not implement — `6e 80 be 00` and then zeros — has a valid
/// checksum, because the seed and the first three bytes cancel exactly. A
/// caller trusting the checksum reads that as a real dial sitting at zero.
///
/// So this also requires the reply to be a feature reply, to carry no error,
/// and to name the code that was asked for. The last is what catches a read
/// taken before the display had settled, which returns the previous reply
/// shifted by a byte or two — bytes that pass a checksum and parse into
/// plausible settings.
EZDDCReading EZDDCParseReply(uint8_t vcp, const uint8_t *reply, size_t length);

/// Whether a reading means the display implements the code.
///
/// A maximum of zero is a refusal too, and in practice the commonest one: some
/// displays answer a code they do not implement with a well-formed reply whose
/// range is empty. A dial that cannot move is not a dial, so this reads it as
/// absent rather than as a display whose volume happens to run from zero to
/// zero.
///
/// Narrower than `outcome != EZDDCReplyGarbled`, and deliberately: this is the
/// question a caller asks before offering a control, where the empty range has
/// to count as absent. The outcome is the question the transport asks before
/// trying again, where a well-formed empty range is still an answer.
bool EZDDCReadingIsSupported(const EZDDCReading &reading);

/// Whether the display settled the question, either way.
///
/// The one thing `EZDDCReadingIsSupported` cannot tell you, because it answers
/// false for a display that said no and for an exchange that failed alike. A
/// capability cache has to tell those apart: the first is knowledge and keeping
/// it saves an exchange per call, the second is the absence of knowledge and
/// keeping it makes one bad read permanent. Cache on this, not on the boolean.
bool EZDDCReadingIsDefinite(const EZDDCReading &reading);

/// The two states a cached range can be in before it holds a range.
///
/// Both are negative so a settled entry is any value from zero up, and zero
/// keeps its meaning: a display that has no such code.
enum {
    EZDDCRangeUnknown     = -2,  ///< Never asked.
    EZDDCRangeUnconfirmed = -1,  ///< Asked once, and the exchange failed.
};

/// Whether a cached range is the display's own answer rather than a placeholder.
inline bool EZDDCRangeIsSettled(int cached) { return cached >= 0; }

/// What the range cache should hold for a code, given what it held and what the
/// display just said.
///
/// A capability cache faces two failures and they pull in opposite directions.
/// Remember a failed read and one bad exchange removes a control for the life
/// of the process, on a monitor that has it. Refuse to remember one and a
/// display whose way of saying "no such code" is the null message is re-probed
/// on every call, at four attempts and about a third of a second each, for as
/// long as the app runs. Neither is acceptable, and no single reading tells
/// them apart — only whether the reading repeats does.
///
/// So a failed read is recorded as `EZDDCRangeUnconfirmed`, which sends the
/// next call back to the display, and only a second consecutive failure settles
/// the code as absent. The cost of a genuine absence is bounded at two reads
/// rather than unbounded, and a false negative needs eight failed attempts in a
/// row on a bus that fails about one in twelve.
///
/// Pure, and separate from the cache it advises, because the version of this
/// decision that lived inside the lookup could not be reached by a test:
/// deleting it wholesale, which reinstates the bug, left the whole suite green.
int EZDDCRangeToRemember(int cached, const EZDDCReading &reading);

/// No value: an empty mailbox, or a code nothing has written yet.
enum { EZDDCNoValue = -1 };

/// What a queued write should do at the moment it runs.
struct EZDDCPendingWrite {
    bool shouldWrite = false;
    int  value       = EZDDCNoValue;
};

/// Whether a queued write still has work to do, given the newest value asked
/// for and the last one sent to the display.
///
/// A slider drag posts one of these per tick and they drain at the speed of an
/// I2C bus, which is far slower than a mouse. Replaying them in order would
/// walk the display through every position the knob passed through, arriving
/// at the right one seconds late. So a work item carries no value of its own:
/// it reads the mailbox when it runs and writes whatever is newest, which
/// makes the ones that never got their turn free to skip.
///
/// The comparison against `lastWritten` is what collapses the tail. Once the
/// knob stops, every item still queued finds the mailbox holding what was just
/// written and does nothing.
///
/// Modeled on MonitorControl, which coalesces this way rather than on a timer.
/// The reason to prefer it is not only that it is the established approach: a
/// timer that fires on the main thread puts the bus round trip in front of the
/// next redraw, and this does not.
EZDDCPendingWrite EZDDCNextWrite(int wanted, int lastWritten);

/// A percentage as a raw value on a dial running from 0 to `maximum`.
///
/// Never assume 100. The reply carries the display's own maximum and panels
/// report 64, 100, and 255, so a percentage written straight through would be
/// a third of the way up a 255-step dial and off the end of a 64-step one.
///
/// Out-of-range input is clamped rather than refused: the parser and the slider
/// both already refuse what a person could get wrong, and the clamp is here so
/// a later caller cannot hand a display a value outside the range it published.
int EZDDCRawFromPercent(int percent, int maximum);

/// The same value back as a whole percentage, or -1 when `maximum` is not a
/// range. Rounded to nearest, so a value set from a percentage reads back as
/// the percentage that was asked for.
int EZDDCPercentFromRaw(int raw, int maximum);

/// Whether a read-back shows a write reached the display.
///
/// A successful write is not an applied write: IOAVServiceWriteI2C reports
/// success once the bus has taken the bytes, whatever the display then does
/// with them. The Philips 34M2C8600 accepts a brightness write, reports
/// success, and discards it, because macOS owns that dial natively.
///
/// Exact equality is the wrong test, though. A display whose volume steps in
/// twos answers 52 to a write of 51, and that write plainly landed. So the dial
/// has to arrive near what was asked rather than exactly on it, and `maximum`
/// sets how near: a twentieth of the range, which is one step of a dial coarse
/// enough for a person to notice the steps.
///
/// Whether the dial *moved* was the test here until a write of 20 landed on 0
/// and was reported as applied, on the reasoning that 0 is not 11. Movement is
/// evidence that the display heard something, and no evidence at all that it
/// heard this. A tolerance on the destination is the honest question, and its
/// failure mode is the safe one: a display quantizing more coarsely than a
/// twentieth reports a write it actually took as untaken, which tells the
/// caller what the dial reads rather than what it hoped.
///
/// `maximum` of 2 gives a tolerance of zero, which is what a code such as mute
/// needs — 1 and 2 are names, not quantities, and near enough is wrong.
bool EZDDCWriteTookEffect(int wanted, int after, int maximum);

/// A volume percentage as a raw value, never landing on 0 unless 0 is what was
/// asked for.
///
/// `EZDDCRawFromPercent` rounds, so on a 64-step dial every percentage below
/// about 0.8 rounds to 0 — and a 0 written to the volume code is a mute, not a
/// quiet setting. MonitorControl carries the same floor with the note that
/// muting this way breaks some displays, which is a worse outcome than being
/// one step louder than asked.
int EZDDCVolumeRawFromPercent(int percent, int maximum);
