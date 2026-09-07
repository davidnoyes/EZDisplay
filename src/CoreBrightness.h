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

/// Night Shift: the warm tint macOS applies on a schedule, one setting for
/// every display at once.
@interface EZNightShift : NSObject

/// Whether this machine can do Night Shift at all. Everything below reports a
/// failure the same way it reports "off", so gate on this first.
+ (BOOL) supported;

/// Whether the tint is switched on. This is the state the toggle in System
/// Settings shows, and it is not the same as the tint being applied right now:
/// a schedule leaves the setting on and the tint off between sunrise and
/// sunset.
+ (BOOL) enabled;

/// Turns it on or off. Returns whether the change was made — the setting reads
/// back immediately, so a caller can re-read rather than assume.
+ (BOOL) setEnabled: (BOOL) enabled;

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
