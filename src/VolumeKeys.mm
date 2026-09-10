//
//  VolumeKeys.mm
//  EZDisplay
//

#import "VolumeKeys.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/hidsystem/IOLLEvent.h>

#include <stdatomic.h>

// The tap and the thread its run loop lives on, both set once and then only
// read. `gTargetCount` is the exception: it is written from the main thread and
// read from the tap thread on every press, so it is atomic.
static CFMachPortRef      gPort;
static CFRunLoopSourceRef gSource;
static void (^gHandler)(EZMediaKeyPress);
static atomic_int         gTargetCount;

/// Which keys this tap took the press of, one bit each. Touched only by the
/// callback, and the callback runs on one thread, so this needs no atomics
/// where `gTargetCount` does.
static int gHeldKeys;


#pragma mark - What macOS can already move

/// Whether a device has a volume macOS can set.
///
/// Three elements, because a device may put its volume on the main element or
/// on each channel and there is no rule about which. The built-in speakers use
/// the main element; a USB headset here uses channels 1 and 2; this monitor
/// uses none of them, which is the case the whole feature exists for.
static BOOL DeviceHasVolume(AudioObjectID device)
{
    for (UInt32 element = 0; element <= 2; element++)
    {
        AudioObjectPropertyAddress address = {
            kAudioDevicePropertyVolumeScalar,
            kAudioObjectPropertyScopeOutput,
            element,
        };
        if (AudioObjectHasProperty(device, &address))
            return YES;
    }
    return NO;
}

/// Whether the volume keys already have something to act on without this app.
///
/// Every failure answers yes, which is the safe way round: not knowing is not a
/// reason to take a key away from whatever else might want it.
static BOOL SystemOwnsVolume(void)
{
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                   0, NULL, &size, &device) != noErr)
        return YES;
    if (device == kAudioObjectUnknown)
        return YES;

    return DeviceHasVolume(device);
}


#pragma mark - The tap

static CGEventRef TapCallback(CGEventTapProxy proxy, CGEventType type,
                              CGEventRef event, void *userInfo)
{
    (void) proxy;
    (void) userInfo;

    // macOS turns a tap off when its callback takes too long, and the only way
    // back is to turn it on again. Nothing else reports this, so a tap that did
    // not handle it would leave the keys dead with no way to tell why.
    if (type == kCGEventTapDisabledByTimeout)
    {
        if (gPort)
            CGEventTapEnable(gPort, true);
        return event;
    }
    if (type == kCGEventTapDisabledByUserInput)
        return event;
    if ((int) type != NX_SYSDEFINED)
        return event;

    // The one AppKit call here, and it is a conversion rather than anything
    // that touches the interface: a system-defined event's payload is not
    // reachable through the CGEvent field accessors. Deliberately not hopped to
    // the main thread first, which is what MediaKeyTap does — main can be
    // sitting in a DDC exchange, and waiting for it is rule 1 in the header.
    NSEvent *systemEvent = [NSEvent eventWithCGEvent: event];
    if (!systemEvent)
        return event;

    const EZMediaKeyPress press = EZDecodeMediaKey((int) systemEvent.subtype,
                                                   systemEvent.data1);
    if (press.key == EZMediaKeyNone)
        return event;

    // Reached only for the first press of a volume key, so the CoreAudio
    // question is asked a few times a second at worst rather than on every
    // event the tap sees — and, more than that, is not asked twice about one
    // hold. A repeat and a release are answered from what this tap did with
    // the press, because the answer can change while the key is down: plug in
    // headphones mid-press and asking again would hand macOS a release for a
    // press it never saw.
    const bool firstPress = press.pressed && !press.repeated;
    const bool intercept  = firstPress
                         && EZMediaKeyShouldIntercept(press.key, SystemOwnsVolume(),
                                                      atomic_load(&gTargetCount) > 0);

    if (!EZMediaKeyTakeEvent(press, intercept, &gHeldKeys))
        return event;

    // Every swallowed event, not only the ones that move something. macOS drew
    // the feedback for the keys it used to get, so this app owes it for the
    // ones it took — and the click for a volume key is on the release, which
    // moves nothing.
    if (gHandler)
    {
        void (^handler)(EZMediaKeyPress) = gHandler;
        const EZMediaKeyPress taken = press;
        dispatch_async(dispatch_get_main_queue(), ^{ handler(taken); });
    }

    // Swallowed, press and release alike. Passing it on as well would let macOS
    // draw the crossed-out speaker over a volume that did in fact just move.
    return NULL;
}


@implementation EZVolumeKeys

+ (BOOL) authorized
{
    return AXIsProcessTrusted();
}

+ (void) requestAuthorization
{
    NSDictionary *options = @{ (__bridge NSString *) kAXTrustedCheckOptionPrompt: @YES };
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
}

+ (void) startWithHandler: (void (^)(EZMediaKeyPress press)) handler
{
    // `gPort` and `gHandler` are written here and read by the callback, which
    // is safe only because this is called from one thread and the tap thread
    // is started after both are set.
    NSAssert(NSThread.isMainThread, @"EZVolumeKeys must be started from the main thread");

    switch (EZVolumeKeysStartAction(AXIsProcessTrusted(), gPort != NULL))
    {
        case EZVolumeKeysStartNothing:
            return;

        case EZVolumeKeysStartEnable:
            // The grant coming back rather than a first start. Revoking
            // Accessibility switches the tap off and leaves the port behind, so
            // the way back is to switch it on again; building a second one
            // would leave the first sitting dead in the chain, still first in
            // line for every event and swallowing nothing.
            CGEventTapEnable(gPort, true);
            return;

        case EZVolumeKeysStartCreate:
            break;
    }

    gHandler = [handler copy];

    gPort = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                             kCGEventTapOptionDefault,
                             CGEventMaskBit(NX_SYSDEFINED),
                             TapCallback, NULL);
    if (!gPort)
    {
        // The grant is in place and the tap was still refused, which is what a
        // sandboxed build looks like. Nothing else in the app depends on it.
        gHandler = nil;
        return;
    }

    gSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gPort, 0);

    // Its own thread, and this is the point of the whole arrangement. On the
    // main run loop the callback would wait behind whatever the interface is
    // doing, including a DDC write this app started, and a tap that waits is a
    // machine that stutters.
    [NSThread detachNewThreadWithBlock: ^{
        [[NSThread currentThread] setName: @"uk.noyes.ezdisplay.keytap"];
        CFRunLoopAddSource(CFRunLoopGetCurrent(), gSource, kCFRunLoopCommonModes);
        CGEventTapEnable(gPort, true);
        CFRunLoopRun();
    }];
}

+ (void) setTargetCount: (NSUInteger) count
{
    atomic_store(&gTargetCount, (int) count);
}

@end
