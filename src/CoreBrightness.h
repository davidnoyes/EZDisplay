//
//  CoreBrightness.h
//  EZDisplay
//
//  Plain Objective-C bridge over the private CoreBrightness framework, so the
//  menu, the Preferences window and the command line read Night Shift and True
//  Tone through one place rather than three.
//
//  Both settings belong to the machine rather than to a display, which is why
//  nothing here takes a CGDirectDisplayID: CoreBrightness offers no per-display
//  entry point for either. Writing the preference files instead does not work,
//  because the daemon holds the live value and ignores a file changed underneath
//  it.
//
//  The framework is private and unversioned, so the classes are looked up by
//  name at runtime, their selectors are checked once when the client is built,
//  and every entry point degrades to NO, 0, or -1 when either is missing. A
//  release that kept a class and renamed one of its methods therefore reports
//  the feature as unavailable rather than raising.
//
//  Call these from the main thread: the writes are fast, and neither can black
//  out the screen, so nothing here needs the apply queue.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Which schedule Night Shift is running, matching the **Schedule** popup in
/// System Settings. The numbers are CoreBrightness's own, confirmed by watching
/// that popup change under `setMode:` rather than taken from a header.
typedef NS_ENUM(NSInteger, EZNightShiftMode) {
    EZNightShiftModeOff    = 0,
    EZNightShiftModeSunset = 1,   // sunset to sunrise, which needs location services
    EZNightShiftModeCustom = 2,   // the window `scheduleFrom` and `scheduleTo` give
};

/// The three things Night Shift can be doing, as one mutually exclusive choice.
///
/// System Settings has the schedule and the **Turn on until tomorrow** checkbox
/// as two independent controls, which lets you set a state — scheduled, and
/// overridden on top — that no single word describes. These three are what a
/// menu can offer, and `mode` and `enabled` are the two dials underneath them.
typedef NS_ENUM(NSInteger, EZNightShiftState) {
    EZNightShiftOff,             // no tint and no schedule
    EZNightShiftUntilTomorrow,   // the tint now, cleared at the next boundary
    EZNightShiftScheduled,       // the schedule decides, with no override on top
};

/// Night Shift: the warm tint macOS applies on a schedule, one setting for
/// every display at once.
@interface EZNightShift : NSObject

/// Whether this machine can do Night Shift at all. Everything below reports a
/// failure the same way it reports "off", so gate on this first.
+ (BOOL) supported;

/// Whether the tint is on right now, whichever thing turned it on: the
/// **Turn on until tomorrow** checkbox, or a schedule whose window covers the
/// time of day. Measured — a custom schedule spanning the current time flipped
/// this from NO to YES with nothing else touched — so a caller gets the live
/// state rather than the manual override alone.
+ (BOOL) enabled;

/// Turns the tint on or off now, which is the **Turn on until tomorrow**
/// checkbox rather than the schedule. macOS clears the override at the next
/// schedule boundary, so this does not survive the way a schedule does.
///
/// Returns whether the change was made — the setting reads back immediately, so
/// a caller can re-read rather than assume.
+ (BOOL) setEnabled: (BOOL) enabled;

/// Which schedule is running, or `EZNightShiftModeOff` when there is none and
/// when the status cannot be read at all. Those two are not told apart, for the
/// same reason `enabled` does not tell a failure from an off: every entry point
/// here degrades to the state that changes nothing.
+ (EZNightShiftMode) mode;

/// Sets it. Going to `EZNightShiftModeCustom` runs the window already stored,
/// so a caller changing both writes the window first.
+ (BOOL) setMode: (EZNightShiftMode) mode;

/// The custom window, as minutes past midnight. Kept whichever mode is running
/// — measured: the daemon still reports 22:00 to 07:00 with the mode at off —
/// so this is what **Custom** goes back to.
///
/// Returns NO and leaves both outputs alone when the status cannot be read.
+ (BOOL) getScheduleFrom: (NSInteger *) fromMinute to: (NSInteger *) toMinute;

/// Sets that window. The two may run backwards by the clock, which is how a
/// schedule spans midnight, and 22:00 to 07:00 is the one macOS ships with.
+ (BOOL) setScheduleFrom: (NSInteger) fromMinute to: (NSInteger) toMinute;

/// Whether sunset to sunrise can be chosen at all. It needs location services,
/// and System Settings drops the choice from its popup without them, so an
/// interface offering it regardless would hand the user a schedule that never
/// fires.
+ (BOOL) sunSchedulePermitted;

/// A schedule in words: `sunset to sunrise`, or `22:00 to 07:00` for a custom
/// one, read from the window stored now. Here rather than at each caller so the
/// menu, the command line, and Preferences name the same schedule alike.
///
/// Takes the mode rather than reading it, because every caller has to describe
/// the schedule that **Scheduled** *would* run, which is not the running one
/// when nothing is running.
+ (NSString *) descriptionOfScheduleMode: (EZNightShiftMode) scheduleMode;

/// Which of the three states is in force, read from `mode` and `enabled`
/// together. A schedule wins: with one running, `enabled` says whether the
/// window covers this minute rather than whether anyone overrode it.
+ (EZNightShiftState) state;

/// Moves to one of the three, which takes both dials because the states are
/// exclusive and each dial can contradict the other.
///
/// `scheduleMode` is which schedule `EZNightShiftScheduled` should run, and is
/// ignored for the other two. It is a parameter rather than something read here
/// because the choice outlives the schedule: turning Night Shift off sets the
/// mode to 0, which is the same place the kind was stored, so whoever offers
/// the choice has to remember it.
+ (BOOL) setState: (EZNightShiftState) state scheduleMode: (EZNightShiftMode) scheduleMode;

/// How warm the tint is, as the whole percentage the interface deals in, or -1
/// when it cannot be read. Zero is a real value, which is why the failure is
/// not one.
+ (NSInteger) warmthPercent;

/// Sets the warmth, which does not turn Night Shift on: the two are separate,
/// as they are in System Settings.
+ (BOOL) setWarmthPercent: (NSInteger) percent;

/// Calls `block` on the main thread whenever Night Shift is switched on or off,
/// including from System Settings, so a menu built from the old value can be
/// rebuilt. A warmth change does not fire it — measured, not assumed.
///
/// One block at a time: registering a second replaces the first, because the
/// private client holds one slot.
+ (void) observeChanges: (void (^)(void)) block;

@end


/// True Tone: the white-balance adjustment for the ambient light in the room.
/// Only some displays have the sensor for it.
@interface EZTrueTone : NSObject

/// Whether True Tone can be used right now. This is the gate to build an
/// interface on, and it is narrower than the framework's `supported`, which
/// reports YES on a Mac whose attached display has no sensor.
+ (BOOL) available;

+ (BOOL) enabled;
+ (BOOL) setEnabled: (BOOL) enabled;

/// As above, on the main thread. Unverified: this machine has no display with a
/// True Tone sensor, so the callback has never been seen to fire. It is
/// registered defensively — if it never arrives, the menu shows the value it was
/// built with instead of a wrong one.
+ (void) observeChanges: (void (^)(void)) block;

@end

NS_ASSUME_NONNULL_END
