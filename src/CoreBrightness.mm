//
//  CoreBrightness.mm
//  EZDisplay
//

#import <dlfcn.h>

#import "CoreBrightness.h"
#import "CommandPlan.h"

// CoreBrightness is private and unversioned, so it is opened by path rather
// than linked. What this file needs from it is Objective-C classes rather than
// C functions, so they are found with NSClassFromString rather than dlsym, and
// a missing one leaves the client nil.
//
// The two protocols below declare only the slice of each class this file calls.
// They exist so the compiler checks the selectors and the argument types; the
// objects are the framework's, and nothing here implements them.

/// The status structure `getBlueLightStatus:` fills, 40 bytes, matching the
/// type encoding the class advertises: `B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16`.
/// Read back against a machine with a 22:00-07:00 schedule, which is where the
/// field order was confirmed rather than guessed.
typedef struct { int hour; int minute; } EZBlueLightTime;
typedef struct { EZBlueLightTime from; EZBlueLightTime to; } EZBlueLightSchedule;
typedef struct {
    // Named from measurement, not from a header nobody has. This first flag was
    // 1 in every state tried — schedule off, schedule on, toggle on, toggle off,
    // mid-afternoon with no tint anywhere — so whatever it reports, it is not
    // "the tint is on now". That is the field below. Nothing here reads this one.
    BOOL                unidentified;
    BOOL                enabled;  // the tint is on, by the toggle or by a schedule
    BOOL                sunSchedulePermitted;
    int                 mode;
    EZBlueLightSchedule schedule;
    unsigned long long  disableFlags;
    BOOL                available;
} EZBlueLightStatus;

@protocol EZBlueLightClient <NSObject>
- (BOOL) supported;
- (BOOL) getBlueLightStatus: (EZBlueLightStatus *) status;
- (BOOL) setEnabled: (BOOL) enabled;
- (BOOL) setMode: (int) mode;
- (BOOL) setSchedule: (const EZBlueLightSchedule *) schedule;
- (BOOL) getStrength: (float *) strength;
- (BOOL) setStrength: (float) strength commit: (BOOL) commit;
- (void) setStatusNotificationBlock: (void (^)(void)) block;
@end

/// The general property reader, here for the one thing the blue light client's
/// structure leaves out: whether an override sits on top of a schedule.
@protocol EZBrightnessSystemClient <NSObject>
- (nullable id) copyPropertyForKey: (NSString *) key;
@end

@protocol EZTrueToneClient <NSObject>
- (BOOL) available;
- (BOOL) enabled;
- (BOOL) setEnabled: (BOOL) enabled;
- (BOOL) registerNotificationCallbackBlock: (void (^)(void)) block
                                 withQueue: (dispatch_queue_t) queue;
@end


static void OpenCoreBrightness(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
               RTLD_LAZY);
    });
}


/// Builds `className`, and hands it back only if it answers every selector in
/// `required`.
///
/// Resolving the class alone is not the same guarantee `ColorMode.mm` gets. A
/// dlsym returns null per function, so a renamed symbol there degrades to
/// unavailable on its own; here the class could survive a macOS release that
/// renamed one of its methods, and the first call would then raise an
/// unrecognized-selector exception rather than reporting NO. Checking once, at
/// construction, keeps the header's promise without a guard at every call.
static id MakeClient(NSString *className, const SEL *required, size_t count)
{
    id client = [[NSClassFromString(className) alloc] init];
    if (client == nil)
        return nil;

    for (size_t i = 0; i < count; i++)
        if (![client respondsToSelector: required[i]])
            return nil;

    return client;
}


// One client each, kept for the life of the process. The notification block
// belongs to the client that registered it, so a client made fresh per call
// would take the observer with it when it went.
//
// Registering for changes is left out of the required lists below and checked
// where it is used: losing the notification costs a menu that goes stale until
// it is next rebuilt, which is worth far less than the whole feature.
static id<EZBlueLightClient> BlueLightClient(void)
{
    static id<EZBlueLightClient> client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OpenCoreBrightness();
        // The two schedule writers are required rather than checked where they
        // are used, unlike the notification below. The menu reads the mode to
        // decide which of its three states is ticked, so a client that can
        // report a schedule but not set one would draw a choice that does
        // nothing when picked. Reporting Night Shift unsupported is the honest
        // outcome, and it is the one the read side already takes.
        const SEL required[] = {
            @selector(supported),
            @selector(getBlueLightStatus:),
            @selector(setEnabled:),
            @selector(setMode:),
            @selector(setSchedule:),
            @selector(getStrength:),
            @selector(setStrength:commit:),
        };
        client = MakeClient(@"CBBlueLightClient", required,
                            sizeof(required) / sizeof(required[0]));
    });
    return client;
}


/// Not required by the blue light client above, for the same reason the
/// notification is not: without it, an override on top of a schedule reads as
/// Scheduled, and the menu ticks the wrong item until the override clears. That
/// costs far less than losing Night Shift altogether.
static id<EZBrightnessSystemClient> BrightnessSystemClient(void)
{
    static id<EZBrightnessSystemClient> client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OpenCoreBrightness();
        const SEL required[] = {
            @selector(copyPropertyForKey:),
        };
        client = MakeClient(@"BrightnessSystemClient", required,
                            sizeof(required) / sizeof(required[0]));
    });
    return client;
}


static id<EZTrueToneClient> TrueToneClient(void)
{
    static id<EZTrueToneClient> client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OpenCoreBrightness();
        const SEL required[] = {
            @selector(available),
            @selector(enabled),
            @selector(setEnabled:),
        };
        client = MakeClient(@"CBTrueToneClient", required,
                            sizeof(required) / sizeof(required[0]));
    });
    return client;
}


/// The live status, or NO when there is nobody to ask.
///
/// Every call into the framework goes through something like this rather than
/// reading the out parameter directly, because a failed call leaves it
/// untouched: an uninitialized struct then reads as plausible state. That is not
/// hypothetical — the command sandbox blocks the daemon these clients talk to,
/// and the first probe written against it reported a schedule and a tint that
/// were stack contents.
static BOOL ReadBlueLightStatus(EZBlueLightStatus *status)
{
    memset(status, 0, sizeof(*status));

    id<EZBlueLightClient> client = BlueLightClient();
    return client != nil && [client getBlueLightStatus: status];
}


/// The daemon's override value, which `stateForMode:enabled:override:`
/// interprets, or -1 when it cannot be read. Each layer is checked, because
/// the dictionary is private and a key that changed type would otherwise raise
/// rather than read as unknown.
static NSInteger ReadBlueLightOverride(void)
{
    NSDictionary *status = [BrightnessSystemClient() copyPropertyForKey: @"CBBlueReductionStatus"];
    if (![status isKindOfClass: [NSDictionary class]])
        return -1;

    NSNumber *value = status[@"BlueLightReductionAlgoOverride"];
    return [value isKindOfClass: [NSNumber class]] ? value.integerValue : -1;
}


@implementation EZNightShift

+ (BOOL) supported
{
    id<EZBlueLightClient> client = BlueLightClient();
    return client != nil && [client supported];
}


+ (BOOL) enabled
{
    EZBlueLightStatus status;
    return ReadBlueLightStatus(&status) && status.enabled;
}


+ (BOOL) setEnabled: (BOOL) enabled
{
    id<EZBlueLightClient> client = BlueLightClient();
    return client != nil && [client setEnabled: enabled];
}


+ (EZNightShiftMode) mode
{
    EZBlueLightStatus status;
    if (!ReadBlueLightStatus(&status))
        return EZNightShiftModeOff;

    // Anything outside the three known values is treated as off rather than
    // passed on: the enum is measured, not documented, and a caller switching
    // on a fourth number would fall through to whichever branch came last.
    switch (status.mode) {
        case EZNightShiftModeSunset: return EZNightShiftModeSunset;
        case EZNightShiftModeCustom: return EZNightShiftModeCustom;
        default:                     return EZNightShiftModeOff;
    }
}


+ (BOOL) setMode: (EZNightShiftMode) mode
{
    id<EZBlueLightClient> client = BlueLightClient();
    return client != nil && [client setMode: (int) mode];
}


+ (BOOL) getScheduleFrom: (NSInteger *) fromMinute to: (NSInteger *) toMinute
{
    EZBlueLightStatus status;
    if (!ReadBlueLightStatus(&status))
        return NO;

    *fromMinute = status.schedule.from.hour * 60 + status.schedule.from.minute;
    *toMinute   = status.schedule.to.hour   * 60 + status.schedule.to.minute;
    return YES;
}


+ (BOOL) setScheduleFrom: (NSInteger) fromMinute to: (NSInteger) toMinute
{
    id<EZBlueLightClient> client = BlueLightClient();
    if (client == nil)
        return NO;

    EZBlueLightSchedule schedule;
    schedule.from.hour   = (int) (fromMinute / 60);
    schedule.from.minute = (int) (fromMinute % 60);
    schedule.to.hour     = (int) (toMinute / 60);
    schedule.to.minute   = (int) (toMinute % 60);
    return [client setSchedule: &schedule];
}


+ (BOOL) sunSchedulePermitted
{
    EZBlueLightStatus status;
    return ReadBlueLightStatus(&status) && status.sunSchedulePermitted;
}


+ (NSString *) descriptionOfScheduleMode: (EZNightShiftMode) scheduleMode
{
    if (scheduleMode == EZNightShiftModeSunset)
        return @"sunset to sunrise";

    NSInteger from = 0, to = 0;
    if (![self getScheduleFrom: &from to: &to])
        return @"a custom window";

    return [NSString stringWithFormat: @"%02ld:%02ld to %02ld:%02ld",
                                       (long) (from / 60), (long) (from % 60),
                                       (long) (to / 60),   (long) (to % 60)];
}


+ (EZNightShiftState) state
{
    return [self stateForMode: [self mode] enabled: [self enabled]
                     override: ReadBlueLightOverride()];
}


+ (EZNightShiftState) stateForMode: (EZNightShiftMode) mode
                           enabled: (BOOL) enabled
                          override: (NSInteger) override
{
    // The daemon's value for an override that turned the tint on. Its value
    // for one that turned it off, 3, has no state of its own here: that
    // schedule is still running and comes back on its own, which is Scheduled.
    static const NSInteger kOverrideTintOn = 4;

    if (enabled && override == kOverrideTintOn)
        return EZNightShiftUntilTomorrow;

    if (mode != EZNightShiftModeOff)
        return EZNightShiftScheduled;

    return enabled ? EZNightShiftUntilTomorrow : EZNightShiftOff;
}


+ (BOOL) setState: (EZNightShiftState) state scheduleMode: (EZNightShiftMode) scheduleMode
{
    // The checkbox, and only the checkbox: the daemon records the override and
    // clears it when the schedule next turns the tint off, which is what hands
    // the tint back to a schedule left running. That holds whether or not the
    // window covers this minute — measured: the override is recorded either way.
    //
    // Unless the override cannot be read back. A schedule left running would
    // then read as Scheduled, and the menu would tick that over the item just
    // picked, so the schedule goes the way it did before this kept it.
    if (state == EZNightShiftUntilTomorrow) {
        if (ReadBlueLightOverride() < 0 && ![self setMode: EZNightShiftModeOff])
            return NO;
        return [self setEnabled: YES];
    }

    // Both dials are written from a known starting point rather than from
    // wherever they happened to be, because each reads through the other.
    // `setEnabled:` with a schedule running does not clear an override, it adds
    // one — measured: `enabled` is YES whenever the window covers this minute,
    // so turning it off inside the window is an override in the other
    // direction. Dropping the mode first clears any override, and makes
    // `enabled` mean only what the checkbox says, which is the one state both
    // writes agree about.
    if (![self setMode: EZNightShiftModeOff])
        return NO;
    if (![self setEnabled: NO])
        return NO;

    if (state != EZNightShiftScheduled)
        return YES;

    return [self setMode: scheduleMode];
}


+ (NSInteger) warmthPercent
{
    id<EZBlueLightClient> client = BlueLightClient();
    float strength = 0;
    if (client == nil || ![client getStrength: &strength])
        return -1;

    return EZPercentFromFraction(strength);
}


+ (BOOL) setWarmthPercent: (NSInteger) percent
{
    id<EZBlueLightClient> client = BlueLightClient();
    // Committed, so the warmth is still there after a restart. Uncommitted it
    // takes effect and survives the process that set it — the daemon holds it —
    // but nothing writes it down.
    return client != nil && [client setStrength: EZFractionFromPercent((int) percent) commit: YES];
}


+ (void) observeChanges: (void (^)(void)) block
{
    id<EZBlueLightClient> client = BlueLightClient();
    if (![client respondsToSelector: @selector(setStatusNotificationBlock:)])
        return;

    // The block the framework calls arrives on one of its own threads, and
    // everything that observes this rebuilds a menu, so the hop to the main
    // thread is made here rather than in each caller.
    [client setStatusNotificationBlock: ^{
        dispatch_async(dispatch_get_main_queue(), block);
    }];
}

@end


@implementation EZTrueTone

+ (BOOL) available
{
    id<EZTrueToneClient> client = TrueToneClient();
    return client != nil && [client available];
}


+ (BOOL) enabled
{
    id<EZTrueToneClient> client = TrueToneClient();
    return client != nil && [client enabled];
}


+ (BOOL) setEnabled: (BOOL) enabled
{
    id<EZTrueToneClient> client = TrueToneClient();
    return client != nil && [client setEnabled: enabled];
}


+ (void) observeChanges: (void (^)(void)) block
{
    id<EZTrueToneClient> client = TrueToneClient();
    if (![client respondsToSelector:
              @selector(registerNotificationCallbackBlock:withQueue:)])
        return;

    // Declared as taking no arguments while the framework's own block may take
    // some. That is safe in this direction and only this one: arguments the
    // callee never reads stay in their registers, whereas declaring arguments
    // the caller does not pass would read whatever those registers held. The
    // signature is not documented anywhere, so it is left at the safe end.
    [client registerNotificationCallbackBlock: ^{
        dispatch_async(dispatch_get_main_queue(), block);
    } withQueue: dispatch_get_main_queue()];
}

@end
