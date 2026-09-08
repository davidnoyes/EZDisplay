//
//  DisplayServices.h
//  EZDisplay
//
//  Plain Objective-C bridge over the private DisplayServices framework, so the
//  menu, the command line and the key handler read one display's brightness
//  through one place rather than three.
//
//  Unlike Night Shift and True Tone, brightness belongs to a display rather
//  than to the machine, so everything here takes a CGDirectDisplayID.
//
//  This is the only brightness route worth taking, even for an external
//  monitor. DDC offers VCP code 0x10 for the same job, and on a display that
//  reports IsSmartDisplay the firmware ignores it: measured on a Philips
//  34M2C8600, the DDC write reported success and changed nothing while
//  DisplayServices moved the same dial immediately. Driving both would leave
//  the slider and the function keys arguing about which value is current.
//
//  The framework is private and unversioned, so it is dlopened and its symbols
//  looked up by name once, and every entry point degrades to NO or -1 when one
//  is missing. Three symbols that older writing assumes are already gone on
//  macOS 26 — DisplayServicesBrightnessChanged, and the two reset calls — so a
//  release that removes another reports the feature as unavailable rather than
//  crashing.
//
//  Call these from the main thread. The writes are fast and none can black out
//  the screen, so nothing here needs the apply queue.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Display brightness, as macOS's own brightness dial rather than the
/// monitor's separate DDC one.
@interface EZBrightness : NSObject

/// Whether this build can reach the framework at all. Gate on this before
/// reporting that a particular display cannot be dimmed, so a missing symbol
/// is not mistaken for a display without the capability.
+ (BOOL) supported;

/// Whether `display` can have its brightness set right now.
///
/// This asks `DisplayServicesCanChangeBrightness`, not whether the panel is
/// built in. The distinction is load-bearing: the attached Philips reports
/// `CGDisplayIsBuiltin` as false and `canChange` as true, so gating on
/// "internal" would hide the control on the one display that has it.
+ (BOOL) availableForDisplay: (CGDirectDisplayID) display;

/// Brightness as a whole percentage, 0 to 100, or -1 when it cannot be read.
/// Zero is a real value — a display can be dimmed all the way — which is why
/// the failure is not one.
///
/// The percentage is the interface's unit throughout, matching how
/// `warmthPercent` handles Night Shift. The framework's own unit is a float
/// from 0 to 1, converted at this boundary and nowhere else.
+ (NSInteger) percentForDisplay: (CGDirectDisplayID) display;

/// Sets it, clamping to 0...100. Returns whether the change was made.
///
/// There are two scales behind this and they disagree: for one state
/// `GetBrightness` read 0.8706 where `GetLinearBrightness` read 0.5717. This
/// uses the former, which is the one the brightness keys move, so the slider
/// and the keys agree about where the dial is.
+ (BOOL) setPercent: (NSInteger) percent forDisplay: (CGDirectDisplayID) display;

/// Calls `block` on the main thread whenever any display's brightness changes,
/// whatever moved it — the function keys, System Settings, or another app — so
/// a menu built from the old value can be rebuilt.
///
/// One block at a time: registering a second replaces the first. Registration
/// is per display, so this re-registers when the display set changes; call it
/// again after a reconfiguration.
+ (void) observeChanges: (void (^)(void)) block;

@end

NS_ASSUME_NONNULL_END
