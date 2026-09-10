//
//  MediaKeys.h
//  EZDisplay
//
//  What a media key press means, as pure functions over the numbers macOS puts
//  in the event.
//
//  The same split `DDCProtocol.h` makes, and for a sharper reason. The half
//  that cannot be tested here is a `CGEventTap`, which runs on a thread of its
//  own and holds up every keystroke on the machine until its callback returns.
//  So everything the callback decides is decided here, where a test can reach
//  it and where nothing can block: three integer comparisons and a table.
//
//  Modeled on MediaKeyTap, the library MonitorControl uses, read in full on
//  2026-09-08. The field layout below is its `NSEventExtensions.swift`, which
//  is the part of it that is not guesswork about an undocumented event.
//

#pragma once

#include <stdint.h>

/// The keys this project acts on.
///
/// Brightness is absent deliberately. macOS drives the function keys against
/// this monitor natively, so a tap over them could only take something away.
enum EZMediaKey {
    EZMediaKeyNone = 0,
    EZMediaKeyVolumeUp,
    EZMediaKeyVolumeDown,
    EZMediaKeyMute,
};

/// A press, as it arrives packed into a system-defined event.
struct EZMediaKeyPress {
    EZMediaKey key      = EZMediaKeyNone;
    bool       pressed  = false;  ///< Down rather than up.
    bool       repeated = false;  ///< The key is being held.
};

/// Unpacks a system-defined event's subtype and `data1` into a press.
///
/// A media key does not arrive as a key event. It arrives as `NX_SYSDEFINED`,
/// subtype 8, with the key code in the high half of `data1` and its state in
/// the low half — and the same subtype carries other things, so both halves
/// have to be read before the event is anything to do with volume.
///
/// Anything that is not one of the three keys comes back as `EZMediaKeyNone`
/// with the flags left alone, so a caller that only looks at `key` cannot
/// mistake an unrelated event for a press.
EZMediaKeyPress EZDecodeMediaKey(int subtype, int64_t data1);

/// Whether a press should move anything.
///
/// A held volume key repeats and should keep stepping, which is how the keys
/// behave everywhere else. A held mute key repeats too, and toggling on each
/// repeat would leave the display muted or not depending on how long the key
/// was held, so mute acts once.
bool EZMediaKeyShouldAct(const EZMediaKeyPress &press);

/// Whether the tap should swallow the event rather than pass it on.
///
/// Three conditions, and the two that are not about the key are what keep this
/// from being theft. `systemHasVolume` is true when the current output device
/// has a volume macOS can set — the built-in speakers, or a headset — and then
/// the keys already do something and are left alone. `hasTarget` is true when
/// some display answers a DDC volume read. Only when macOS has nothing to move
/// and this app has something to move are the keys worth taking.
///
/// Decided on the key rather than on `EZMediaKeyShouldAct`, so a key whose
/// press does not move anything is still taken — mute's repeats act once but
/// every one of them is swallowed.
///
/// Asked once per hold, for the first press. What happens to the repeats and
/// the release after that is `EZMediaKeyTakeEvent`'s decision, taken from what
/// this answered rather than by asking again.
bool EZMediaKeyShouldIntercept(EZMediaKey key, bool systemHasVolume, bool hasTarget);

/// Whether the tap should swallow this event, given what it did with the press.
///
/// `held` is a bitmask of the keys whose press was taken, which this updates.
/// It exists because the gate is not a constant: the default output device can
/// change while a key is down, and asking again at the release would answer a
/// different question from the one the press asked. Then a key this app took
/// the press of would have its release handed to macOS, which never saw the
/// press — half an event, and the thing the gate is supposed to prevent.
///
/// So a release is swallowed because its press was, and for no other reason.
///
/// `intercept` answers the gate and is read only for the first press of a hold,
/// so a caller can leave the CoreAudio question unasked on a repeat or a
/// release — which is the point, because asking it there is what went wrong.
bool EZMediaKeyTakeEvent(const EZMediaKeyPress &press, bool intercept, int *held);

/// What starting the key watcher should do, given what it finds.
enum EZVolumeKeysStart {
    EZVolumeKeysStartNothing = 0,  ///< No grant, so there is nothing to install.
    EZVolumeKeysStartEnable,       ///< A tap exists and only needs switching on.
    EZVolumeKeysStartCreate,       ///< The grant is there and no tap is.
};

/// Decides between those three.
///
/// The whole of `startWithHandler:` that is not a system call, pulled out here
/// because the version that lived inline got one of the three wrong and no test
/// could reach it. Revoking Accessibility switches a tap off without destroying
/// it, so `tapExists` and `authorized` are independent: the combination that
/// matters is a port that is still there and a grant that has come back, and
/// the inline version answered that one by returning.
EZVolumeKeysStart EZVolumeKeysStartAction(bool authorized, bool tapExists);

/// Where a volume key takes a percentage.
///
/// Sixteen steps, which is what macOS's own volume keys use, so the dial moves
/// by the amount a person expects from pressing that key anywhere else. Both
/// directions move to the next step past where the dial is rather than to a
/// step counted from the nearest one: a display sitting at 47, because its own
/// buttons put it there, goes up to 50 rather than skipping to 56.
///
/// Clamped to 0...100, and a key that is not a volume key returns `percent`
/// unchanged.
int EZVolumeAfterKey(int percent, EZMediaKey key);

/// Whether a volume key press leaves the row with anything to write.
///
/// Normally a press that does not move the dial does not: the display is at 100
/// and up was pressed, and the write would be a bus exchange to change nothing.
///
/// Muted is the exception, and it is the exception because muting does not move
/// the dial. A display muted at 100 answers volume up with 100, so the one press
/// a person makes to bring the sound back was the one press that went nowhere.
///
/// This is only about a press that would otherwise be skipped, so the `next > 0`
/// term is not a rule that mute lifts upward only: a muted display at 50 asked
/// to go down moves the dial, which reaches the display on `next != now` alone,
/// and lifting mute on the way is the caller's business. The term is here for
/// the one press that has nothing behind it — muted at zero, asked to go lower,
/// which is being asked for what it is already doing.
bool EZVolumeRowNeedsWrite(int now, int next, bool muted);

/// How many chiclets the feedback panel draws.
///
/// Sixteen, the same sixteen steps `EZVolumeAfterKey` moves in, so one press
/// moves the bar by exactly one and no press leaves it where it was.
const int kEZVolumeChiclets = 16;

/// How many of them are lit for a display at `percent`.
///
/// Muted lights none rather than dimming the bar, because a bar left standing
/// where it was would say the sound is still coming out.
///
/// `percent` is clamped, because it comes from a DDC read and can be anything.
int EZVolumeChicletsLit(int percent, bool muted);

/// Whether this event is the one that plays the feedback click.
///
/// The edge is the whole of the native feel, and it differs by key. A volume
/// key clicks when it comes back *up*, so holding it ratchets the bar in
/// silence and clicks once rather than sixteen times. Mute clicks on the press.
///
/// `enabled` is System Settings › Sound › **Play feedback when volume is
/// changed**, which governs the click for every key and both edges.
bool EZShouldPlayVolumeFeedback(const EZMediaKeyPress &press, bool enabled);
