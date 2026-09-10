//
//  DisplayServices.mm
//  EZDisplay
//
//  See DisplayServices.h.
//

#import <dlfcn.h>

#import "DisplayServices.h"
#import "CommandPlan.h"

// DisplayServices is private and unversioned, so it is opened by path rather
// than linked, and every entry point is a C function found with dlsym. A symbol
// that a macOS release renames comes back null and the feature reports itself
// unavailable, which is the same degradation ColorMode.mm takes.

typedef int  (*EZGetBrightnessFn)(CGDirectDisplayID display, float *brightness);
typedef int  (*EZSetBrightnessFn)(CGDirectDisplayID display, float brightness);
typedef BOOL (*EZCanChangeBrightnessFn)(CGDirectDisplayID display);
typedef int  (*EZRegisterFn)(CGDirectDisplayID display, CGDirectDisplayID observer,
                             CFNotificationCallback callback);
typedef int  (*EZUnregisterFn)(CGDirectDisplayID display, CGDirectDisplayID observer);

static EZGetBrightnessFn       gGetBrightness;
static EZSetBrightnessFn       gSetBrightness;
static EZCanChangeBrightnessFn gCanChangeBrightness;
static EZRegisterFn            gRegister;
static EZUnregisterFn          gUnregister;


/// Resolves the symbols once. The two notification calls are looked up but not
/// required: losing them costs a slider that goes stale until the menu is next
/// rebuilt, which is worth far less than the whole feature — the same call
/// CoreBrightness.mm makes about its own notification block.
static void OpenDisplayServices(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
               RTLD_LAZY);

        gGetBrightness = (EZGetBrightnessFn)
            dlsym(RTLD_DEFAULT, "DisplayServicesGetBrightness");
        gSetBrightness = (EZSetBrightnessFn)
            dlsym(RTLD_DEFAULT, "DisplayServicesSetBrightness");
        gCanChangeBrightness = (EZCanChangeBrightnessFn)
            dlsym(RTLD_DEFAULT, "DisplayServicesCanChangeBrightness");
        gRegister = (EZRegisterFn)
            dlsym(RTLD_DEFAULT, "DisplayServicesRegisterForBrightnessChangeNotifications");
        gUnregister = (EZUnregisterFn)
            dlsym(RTLD_DEFAULT, "DisplayServicesUnregisterForBrightnessChangeNotifications");
    });
}


// The observer, and the displays it is currently registered for. Registration
// is per display, so the list is kept in order to take each one back off again
// when the display set changes; unregistering a display that was never
// registered is not something the private call promises to survive.
//
// Globals because a CFNotificationCallback is a plain C function pointer with
// nothing to capture into. That is what rules out the shape CoreBrightness.mm
// uses, where the caller's block is captured by the block handed to the
// framework and no shared state exists at all.
//
// Read and written on the main thread only. That is not a convention, it is
// what makes them safe: the framework calls back on a thread of its own —
// measured as thread 2, not main — and `observeChanges:` replaces both on every
// display reconfiguration, so an off-main read of `gObserver` would race the
// main thread's release of the block it is reading.
static void (^gObserver)(void);
static NSMutableArray<NSNumber *> *gObserved;


static void BrightnessChanged(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object,
                              CFDictionaryRef userInfo)
{
    // The new value arrives in `userInfo["value"]` and is deliberately ignored:
    // one block serves every display, so a caller that wants a number reads the
    // display it cares about rather than being handed one it may not.
    //
    // The hop to the main thread comes before the read of gObserver rather than
    // after it, which is the whole reason no lock is needed. It also reads
    // whichever observer is current when the menu is actually updated, rather
    // than the one that happened to be installed when the key was pressed.
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^block)(void) = gObserver;
        if (block != nil)
            block();
    });
}


@implementation EZBrightness

+ (BOOL) supported
{
    OpenDisplayServices();
    return gGetBrightness != NULL && gSetBrightness != NULL
        && gCanChangeBrightness != NULL;
}


+ (BOOL) availableForDisplay: (CGDirectDisplayID) display
{
    return [self supported] && gCanChangeBrightness(display);
}


+ (NSInteger) percentForDisplay: (CGDirectDisplayID) display
{
    OpenDisplayServices();
    if (gGetBrightness == NULL)
        return -1;

    // Zeroed first, and the return code checked, for the reason
    // ReadBlueLightStatus gives: a failed call leaves the out parameter alone,
    // and an uninitialized float reads back as a plausible brightness.
    float brightness = 0;
    if (gGetBrightness(display, &brightness) != 0)
        return -1;

    return EZPercentFromFraction(brightness);
}


+ (BOOL) setPercent: (NSInteger) percent forDisplay: (CGDirectDisplayID) display
{
    OpenDisplayServices();
    if (gSetBrightness == NULL)
        return NO;

    return gSetBrightness(display, EZFractionFromPercent((int) percent)) == 0;
}


+ (void) observeChanges: (void (^)(void)) block
{
    OpenDisplayServices();
    if (gRegister == NULL || gUnregister == NULL)
        return;

    for (NSNumber *display in gObserved)
        gUnregister((CGDirectDisplayID) display.unsignedIntValue, 0);

    gObserved = [NSMutableArray array];
    gObserver = block;

    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(sizeof(displays) / sizeof(displays[0]),
                               displays, &count) != kCGErrorSuccess)
        return;

    for (uint32_t i = 0; i < count; i++) {
        if (gRegister(displays[i], 0, BrightnessChanged) != 0)
            continue;
        [gObserved addObject: @(displays[i])];
    }
}

@end
