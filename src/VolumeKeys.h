//
//  VolumeKeys.h
//  EZDisplay
//
//  The volume keys, redirected to a monitor's own speakers.
//
//  This is the half of the feature that cannot be tested: a `CGEventTap`, the
//  Accessibility grant it needs, and the CoreAudio question of whether macOS
//  already has a volume of its own to move. Every decision it makes is made by
//  `MediaKeys.h`, which is pure and covered.
//
//  A tap is a serious thing to install. Its callback runs ahead of every other
//  handler for the events it asks for, and while it is running the keystroke
//  has not been delivered to anything — so a slow callback is a machine that
//  stutters when you type. Two rules follow, and both are load-bearing:
//
//  1. The callback never blocks. No DDC exchange, no lock held across one, and
//     no hop to the main thread that waits for an answer. Main can be sitting
//     in a DDC write for a tenth of a second, and a tap that waited for it
//     would be disabled by macOS for taking too long.
//  2. The keys are taken only when they would otherwise do nothing. That is
//     the whole justification for the tap: this monitor publishes no volume
//     CoreAudio can set, so the keys are dead against it. Plug in headphones
//     and macOS has a dial again, and the keys go straight back to it.
//
//  Without the Accessibility grant no tap exists, and nothing else changes: the
//  menu, the slider, and the subcommand all work as they did. Granting it later
//  needs no restart — call `startWithHandler:` again.
//

#import <Foundation/Foundation.h>

// Objective-C++ only, because `EZMediaKeyPress` is a C++ struct. Swift reaches
// this header through the bridging header, which is compiled as Objective-C, and
// everything below that mentions a media key is hidden from it for that reason.
// What is left — the two Accessibility calls — is what the Settings window needs
// and all it needs, so the alternative was a second copy of the permission logic
// on the Swift side.
#ifdef __cplusplus
#import "MediaKeys.h"
#endif

NS_ASSUME_NONNULL_BEGIN

@interface EZVolumeKeys : NSObject

/// Whether macOS has granted this app the Accessibility permission a tap needs.
+ (BOOL) authorized;

/// Asks for it, which shows the system's own prompt the first time and opens
/// System Settings from there. Returns without waiting: the answer arrives as a
/// `com.apple.accessibility.api` distributed notification.
+ (void) requestAuthorization;

/// Starts watching the keys, and does nothing at all when not authorized.
///
/// `handler` runs on the main thread, once for every event this tap swallowed,
/// and is kept from the first call that installs a tap.
///
/// Every event, not only the ones that move something, because the feedback is
/// not on the same edge as the change: a volume key clicks when it comes back
/// up. `EZMediaKeyShouldAct` is the caller's to ask, and the release it is
/// false for is the one the click needs.
///
/// Call it from the main thread, and call it as often as you like: a second
/// call switches the existing tap back on rather than building another. That
/// matters because revoking Accessibility disables the tap without destroying
/// it, so re-enabling is exactly what a returning grant needs — and it is what
/// makes the grant usable without a restart.
#ifdef __cplusplus
+ (void) startWithHandler: (void (^)(EZMediaKeyPress press)) handler;
#endif

/// How many displays the keys have something to say to.
///
/// Zero passes every key straight through, so a Mac with no DDC-capable
/// speakers behaves as though this file did not exist. Set it from wherever the
/// display list is worked out; nothing here goes looking.
+ (void) setTargetCount: (NSUInteger) count;

@end

NS_ASSUME_NONNULL_END
