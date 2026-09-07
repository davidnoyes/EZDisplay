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
    BOOL                active;   // the tint is being applied right now
    BOOL                enabled;  // the setting is switched on
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
- (BOOL) getStrength: (float *) strength;
- (BOOL) setStrength: (float) strength commit: (BOOL) commit;
- (void) setStatusNotificationBlock: (void (^)(void)) block;
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
/// unrecognised-selector exception rather than reporting NO. Checking once, at
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
        const SEL required[] = {
            @selector(supported),
            @selector(getBlueLightStatus:),
            @selector(setEnabled:),
            @selector(getStrength:),
            @selector(setStrength:commit:),
        };
        client = MakeClient(@"CBBlueLightClient", required,
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
/// untouched: an uninitialised struct then reads as plausible state. That is not
/// hypothetical — the command sandbox blocks the daemon these clients talk to,
/// and the first probe written against it reported a schedule and a tint that
/// were stack contents.
static BOOL ReadBlueLightStatus(EZBlueLightStatus *status)
{
    memset(status, 0, sizeof(*status));

    id<EZBlueLightClient> client = BlueLightClient();
    return client != nil && [client getBlueLightStatus: status];
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


+ (NSInteger) warmthPercent
{
    id<EZBlueLightClient> client = BlueLightClient();
    float strength = 0;
    if (client == nil || ![client getStrength: &strength])
        return -1;

    return EZPercentFromWarmth(strength);
}


+ (BOOL) setWarmthPercent: (NSInteger) percent
{
    id<EZBlueLightClient> client = BlueLightClient();
    // Committed, so the warmth is still there after a restart. Uncommitted it
    // takes effect and survives the process that set it — the daemon holds it —
    // but nothing writes it down.
    return client != nil && [client setStrength: EZWarmthFromPercent((int) percent) commit: YES];
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
