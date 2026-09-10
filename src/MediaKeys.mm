//
//  MediaKeys.mm
//  EZDisplay
//

#include "MediaKeys.h"

// From IOKit's ev_keymap.h and IOLLEvent.h. Repeated rather than imported so
// this file stays free of IOKit and can be linked into a test target that has
// no reason to pull the framework in.
enum {
    kSoundUp   = 0,
    kSoundDown = 1,
    kMute      = 7,
};

/// NX_SUBTYPE_AUX_CONTROL_BUTTONS. Other subtypes ride on the same event type
/// and pack their own meaning into the same field.
static const int kAuxControlButtons = 8;

// The low half of `data1`: a state in the high byte, and a repeat bit at the
// bottom. 0x0A is down and 0x0B is up.
enum {
    kStateDown  = 0x0A,
    kRepeatMask = 0x1,
};

/// The number of steps a volume key crosses the range in, which is what macOS
/// uses for its own. The same number the feedback panel draws chiclets for, and
/// tied to it here rather than written twice, because one press has to move the
/// bar by exactly one.
static const int kDetents = kEZVolumeChiclets;

static int Clamp(int value, int low, int high)
{
    if (value < low)  return low;
    if (value > high) return high;
    return value;
}

/// The percentage of one of the sixteen steps, rounded to whole percent.
static int DetentValue(int index)
{
    return (index * 100 + kDetents / 2) / kDetents;
}

EZMediaKeyPress EZDecodeMediaKey(int subtype, int64_t data1)
{
    EZMediaKeyPress press;

    if (subtype != kAuxControlButtons)
        return press;

    const int keyCode = (int) ((data1 & 0xFFFF0000) >> 16);
    switch (keyCode)
    {
        case kSoundUp:   press.key = EZMediaKeyVolumeUp;   break;
        case kSoundDown: press.key = EZMediaKeyVolumeDown; break;
        case kMute:      press.key = EZMediaKeyMute;       break;
        default:         return press;
    }

    const int keyFlags = (int) (data1 & 0x0000FFFF);
    press.pressed  = ((keyFlags & 0xFF00) >> 8) == kStateDown;
    press.repeated = (keyFlags & kRepeatMask) == kRepeatMask;
    return press;
}

bool EZMediaKeyShouldAct(const EZMediaKeyPress &press)
{
    if (press.key == EZMediaKeyNone)
        return false;
    if (!press.pressed)
        return false;
    return !(press.repeated && press.key == EZMediaKeyMute);
}

bool EZMediaKeyShouldIntercept(EZMediaKey key, bool systemHasVolume, bool hasTarget)
{
    return key != EZMediaKeyNone && !systemHasVolume && hasTarget;
}

int EZVolumeAfterKey(int percent, EZMediaKey key)
{
    const int from = Clamp(percent, 0, 100);

    // The next step past where the dial is, in whichever direction. Walking the
    // ladder rather than indexing into it is what makes a value between two
    // steps move to the one beside it instead of to the one after that.
    if (key == EZMediaKeyVolumeUp)
    {
        for (int i = 0; i <= kDetents; i++)
            if (DetentValue(i) > from)
                return DetentValue(i);
        return 100;
    }

    if (key == EZMediaKeyVolumeDown)
    {
        for (int i = kDetents; i >= 0; i--)
            if (DetentValue(i) < from)
                return DetentValue(i);
        return 0;
    }

    return percent;
}

bool EZVolumeRowNeedsWrite(int now, int next, bool muted)
{
    return next != now || (muted && next > 0);
}

int EZVolumeChicletsLit(int percent, bool muted)
{
    if (muted)
        return 0;

    // Rounded rather than truncated, so a display sitting between two steps
    // reads as the chiclet it is nearer to. Truncating would show 94 as one
    // short of full when the next press is the last one.
    const int from = Clamp(percent, 0, 100);
    return (from * kEZVolumeChiclets + 50) / 100;
}

bool EZIsVolumeFeedbackMoment(const EZMediaKeyPress &press)
{
    if (press.key == EZMediaKeyNone)
        return false;

    // Mute acts on its press and acts once, so that is where its feedback goes.
    if (press.key == EZMediaKeyMute)
        return press.pressed && !press.repeated;

    // A volume key acts on every repeat, so feedback there would be a burst of
    // it. The release is the one event a hold has exactly one of.
    return !press.pressed;
}

bool EZShouldPlayVolumeFeedback(const EZMediaKeyPress &press, bool enabled)
{
    return enabled && EZIsVolumeFeedbackMoment(press);
}

bool EZMediaKeyTakeEvent(const EZMediaKeyPress &press, bool intercept, int *held)
{
    if (press.key == EZMediaKeyNone)
        return false;

    // One bit per key, so two keys held at once release independently.
    const int bit = 1 << (int) press.key;

    if (press.pressed)
    {
        // A repeat belongs to the hold that started it, so the gate is asked
        // once per hold rather than once per event. Whoever took the first
        // press keeps the rest of it, in both directions: this app does not
        // hand macOS a repeat it has no press for, and does not take one off
        // it midway either.
        if (press.repeated)
            return (*held & bit) != 0;

        if (!intercept)
        {
            // Passed on, and recorded as passed on. A fresh press restarts the
            // latch whichever way it goes, so a bit left set by a release this
            // tap never saw cannot outlive it.
            *held &= ~bit;
            return false;
        }
        *held |= bit;
        return true;
    }

    if (!(*held & bit))
        return false;

    *held &= ~bit;
    return true;
}

EZVolumeKeysStart EZVolumeKeysStartAction(bool authorized, bool tapExists)
{
    if (!authorized)
        return EZVolumeKeysStartNothing;

    return tapExists ? EZVolumeKeysStartEnable : EZVolumeKeysStartCreate;
}
