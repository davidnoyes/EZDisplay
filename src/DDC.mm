//
//  DDC.mm
//  EZDisplay
//

#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <unistd.h>

#include <atomic>
#include <vector>

#import "DDC.h"
#import "DDCProtocol.h"
#import "DisplayPort.h"

// IOAVService is private and unversioned, so it is reached through dlsym rather
// than linked. All three symbols are needed together: without them there is no
// I2C bus to talk over, and every entry point below reports the feature absent.

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*FnAVCreate)(CFAllocatorRef, io_service_t);
typedef IOReturn       (*FnAVRead)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn       (*FnAVWrite)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

static FnAVCreate gAVCreate;
static FnAVRead   gAVRead;
static FnAVWrite  gAVWrite;

static void ResolveSymbols(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);

        gAVCreate = (FnAVCreate)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
        gAVRead   = (FnAVRead)  dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
        gAVWrite  = (FnAVWrite) dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    });
}

// The bus addresses. Both go to IOAVService as arguments rather than into the
// buffer, which is why DDCProtocol.h folds them into its checksums instead.
enum {
    kChipAddress = 0x37,
    kDataAddress = 0x51,
    kReadOffset  = 0x00,  // reads take no data address
};

// These timings are what is proven on Apple silicon rather than what the
// specification asks for, which is the whole reason they are these numbers.
// Shortening any of them is not a tuning exercise: too little settle time
// returns the previous exchange's bytes, which pass a checksum and parse into
// a plausible setting.
//
// Together these put about 90 ms into every exchange, which is why the results
// are cached and why the header tells a slider to coalesce.
static const useconds_t kSettleBeforeWrite  = 10000;
static const useconds_t kSettleBeforeRead   = 50000;
static const useconds_t kSettleBetweenTries = 20000;

// The request goes twice, because displays in the wild need it: the first
// frame is dropped often enough that a single write reads back unchanged and
// looks like a display refusing the code.
static const int kWriteCycles  = 2;
static const int kReadAttempts = 4;

#pragma mark - One exchange

// Puts a request on the bus. The buffer is copied by the call, but the private
// signature takes it non-const, so it is not declared const here.
static IOReturn SendRequest(IOAVServiceRef service, uint8_t *packet, size_t length)
{
    IOReturn rc = kIOReturnError;
    for (int cycle = 0; cycle < kWriteCycles; cycle++)
    {
        // Inside the loop, not before it. The delay separates the two frames
        // as much as it precedes the first, and sending them back to back is
        // measurably not the same thing: with one sleep out here, a set of the
        // volume code drove this monitor's dial to zero rather than to the
        // value asked for, whatever value that was.
        usleep(kSettleBeforeWrite);
        rc = gAVWrite(service, kChipAddress, kDataAddress, packet, (uint32_t) length);
    }
    return rc;
}

/// Asks `service` for one code, retrying until the display settles it.
///
/// A retry is worth making for anything that is not the display's own verdict,
/// which includes the null message: that frame is well formed and says nothing,
/// and this monitor sends one every dozen or so exchanges for a code it answers
/// properly the rest of the time. A display that answers "no such code" has
/// answered, and asking four more times would put most of half a second into a
/// question already settled — see `EZDDCReplyOutcome`.
static EZDDCReading ReadVCP(IOAVServiceRef service, uint8_t vcp)
{
    IOReturn rc = kIOReturnError;

    for (int attempt = 0; attempt < kReadAttempts; attempt++)
    {
        if (attempt > 0)
            usleep(kSettleBetweenTries);

        uint8_t request[EZDDCReadRequestLength];
        const size_t requested = EZDDCBuildReadRequest(vcp, request);

        rc = SendRequest(service, request, requested);
        if (rc == kIOReturnNoDevice)
            break;

        usleep(kSettleBeforeRead);

        uint8_t reply[EZDDCReplyLength] = {0};
        rc = gAVRead(service, kChipAddress, kReadOffset, reply, (uint32_t) sizeof(reply));
        if (rc == kIOReturnNoDevice)
            break;

        if (rc == kIOReturnSuccess)
        {
            EZDDCReading reading = EZDDCParseReply(vcp, reply, sizeof(reply));
            if (EZDDCReadingIsDefinite(reading))
                return reading;
        }
    }

    return EZDDCReading();
}

static BOOL WriteVCP(IOAVServiceRef service, uint8_t vcp, uint16_t value)
{
    uint8_t request[EZDDCWriteRequestLength];
    const size_t length = EZDDCBuildWriteRequest(vcp, value, request);
    return SendRequest(service, request, length) == kIOReturnSuccess;
}

#pragma mark - Finding the display's service

static BOOL ServiceIsExternal(io_service_t service)
{
    CFTypeRef location = IORegistryEntryCreateCFProperty(service, CFSTR("Location"),
                                                         kCFAllocatorDefault, 0);
    BOOL external = location
                 && CFGetTypeID(location) == CFStringGetTypeID()
                 && CFStringCompare((CFStringRef) location, CFSTR("External"), 0)
                        == kCFCompareEqualTo;
    if (location)
        CFRelease(location);
    return external;
}

/// The AV service for `display`, or NULL.
///
/// Two things make this more than a lookup. One monitor is exposed as several
/// DCPAVServiceProxy entries on the same port, and only one of them has the
/// bus behind it — the others answer kIOReturnNoDevice — so each candidate is
/// probed with a read and the one that answers is the one kept. And a display
/// whose port cannot be identified gets no service at all rather than the first
/// external proxy that turns up: sending one monitor's volume to another is
/// exactly the failure the port matching exists to prevent.
///
/// `outcome` says why when the answer is NULL, which decides how long that
/// answer is kept: see `EZDDCLookupOutcome`.
static IOAVServiceRef CopyServiceForDisplay(CGDirectDisplayID display, EZDDCLookup *outcome)
{
    *outcome = EZDDCLookupAbsent;

    NSString *portNode = EZPortNodeForDisplay(display);
    if (!portNode)
        return NULL;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("DCPAVServiceProxy"),
                                     &iter) != KERN_SUCCESS)
        return NULL;

    int probed = 0;
    IOAVServiceRef chosen = NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iter)))
    {
        if (!chosen && ServiceIsExternal(service) && EZServiceIsOnPort(service, portNode))
        {
            IOAVServiceRef candidate = gAVCreate(kCFAllocatorDefault, service);
            if (candidate)
            {
                // Any answer proves the bus is there, including a refusal: this
                // asks whether the proxy is the live one, not whether the
                // display has speakers.
                //
                // The answer, not the return code. A read whose every attempt
                // came back garbled still ends with the transport reporting
                // success — the I2C transaction went through and the payload
                // was rubbish — so judging by the return code would let a proxy
                // that never said anything coherent claim the slot. It is the
                // only candidate examined once chosen, so the live one behind
                // it would never be probed, and a monitor with a volume control
                // would report that it has none.
                const EZDDCReading probe = ReadVCP(candidate, EZVCPSpeakerVolume);
                probed++;

                if (EZDDCReadingIsDefinite(probe))
                    chosen = candidate;
                else
                    CFRelease(candidate);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    *outcome = EZDDCLookupOutcome(probed, chosen != NULL);
    return chosen;
}

#pragma mark - The bus queue

/// The one queue every DDC exchange runs on, for every display.
///
/// Serial and global rather than one per display, for two separate reasons.
/// Displays on the same Mac do not necessarily have independent I2C buses, so
/// overlapping exchanges can interleave into each other's replies; and the
/// caches below are plain dictionaries, so a background write and a menu being
/// built would otherwise race on them.
///
/// Everything public either runs its body here with `dispatch_sync`, which is
/// what the callers already did by being on the main thread, or posts to it and
/// returns. The static functions in this file assume they are already on it and
/// must never dispatch to it themselves.
static dispatch_queue_t BusQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("uk.noyes.ezdisplay.ddc", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

#pragma mark - Caches

// Both are keyed by display ID and both are dropped wholesale on
// reconfiguration, because after one a port may hold a different monitor.
static NSMutableDictionary<NSNumber *, id> *gServices;  // NSNull once looked for and absent
static NSMutableDictionary<NSNumber *, NSNumber *> *gRanges;  // 0 once known unsupported

// The newest value asked for, and the last one sent to the display, per display
// and code. See `EZDDCNextWrite` for what a queued write does with the pair.
//
// These are the one thing here not owned by the bus queue, and deliberately: a
// mailbox update has to overtake the writes it supersedes, and one posted to
// the bus queue would instead queue behind them and arrive too late to
// supersede anything. So they take a lock, which is held for a dictionary
// access and never across an exchange.
static NSMutableDictionary<NSNumber *, NSNumber *> *gWanted;
static NSMutableDictionary<NSNumber *, NSNumber *> *gWritten;
static os_unfair_lock gMailboxLock = OS_UNFAIR_LOCK_INIT;

/// Forgets every service and range, and what was last written. On the bus
/// queue, like the functions that fill them.
///
/// What was written goes because a value written to the monitor that was on a
/// port says nothing about the one there now, and leaving it would let the
/// first write to the new display be skipped as a duplicate.
///
/// What was wanted stays. It is the user's latest value rather than anything
/// the display said, and a drop can land between a key press recording it and
/// the queued write that reads it back: clearing it there would make that write
/// find nothing to send, and the press would vanish without a failure to show.
static void DropCaches(void)
{
    gServices = nil;
    gRanges   = nil;

    os_unfair_lock_lock(&gMailboxLock);
    gWritten = nil;
    os_unfair_lock_unlock(&gMailboxLock);
}

#pragma mark - Watching the proxies

NSNotificationName const EZDisplayAudioServicesChangedNotification =
    @"EZDisplayAudioServicesChangedNotification";

static void Drain(io_iterator_t iterator)
{
    io_service_t service;
    while ((service = IOIteratorNext(iterator)))
        IOObjectRelease(service);
}

/// A proxy appeared or went away, so whatever is cached may be a dead port or
/// a stale "no service here". Either way the next exchange looks again.
///
/// Both directions, not only termination. A lookup made while the monitor had
/// no proxy cached it as absent, and only the proxy's return clears that.
///
/// Every display's entries go, not only the one whose proxy changed. Telling
/// which display a proxy belongs to would take the same port matching and bus
/// probe the lookup does, inside a callback; dropping everything costs one
/// fresh lookup per display on its next use, a handful of times at a wake.
static void ProxiesChanged(void *refcon, io_iterator_t iterator)
{
    Drain(iterator);
    DropCaches();

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName: EZDisplayAudioServicesChangedNotification object: nil];
    });
}

// Delivered on the bus queue, so a drop lands between exchanges rather than
// under one: a service borrowed from the cache is only used inside a single
// block on that queue.
BOOL EZDDCWatchProxies(void)
{
    static BOOL watching;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IONotificationPortRef port = IONotificationPortCreate(kIOMasterPortDefault);
        if (!port)
            return;
        IONotificationPortSetDispatchQueue(port, BusQueue());

        // Each subscription consumes its matching dictionary, and each iterator
        // has to be drained once before it will deliver anything. The first
        // drain is the proxies already there, which change nothing.
        io_iterator_t matched = 0, terminated = 0;
        const BOOL added =
            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                             IOServiceMatching("DCPAVServiceProxy"),
                                             ProxiesChanged, NULL, &matched) == KERN_SUCCESS
         && IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                             IOServiceMatching("DCPAVServiceProxy"),
                                             ProxiesChanged, NULL, &terminated) == KERN_SUCCESS;
        // Half a subscription is taken down rather than left running, so that
        // not watching means nothing is watching.
        if (!added)
        {
            IOObjectRelease(matched);
            IOObjectRelease(terminated);
            IONotificationPortDestroy(port);
            return;
        }

        Drain(matched);
        Drain(terminated);
        watching = YES;
    });
    return watching;
}

/// What `gServices` holds for a display whose proxy was there and did not
/// answer, beside `NSNull` for one with nothing to ask. Both stop the next call
/// from probing again, since a probe that fails can take most of a second; only
/// this one is looked at again, by `lookAgainWhereUnanswered:`.
static id Unanswered(void)
{
    static NSObject *unanswered;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ unanswered = [NSObject new]; });
    return unanswered;
}

static IOAVServiceRef ServiceForDisplay(CGDirectDisplayID display)
{
    ResolveSymbols();
    if (!gAVCreate || !gAVRead || !gAVWrite)
        return NULL;

    EZDDCWatchProxies();

    if (!gServices)
        gServices = [NSMutableDictionary dictionary];

    id cached = gServices[@(display)];
    if (cached == [NSNull null] || cached == Unanswered())
        return NULL;
    if (cached)
        return (__bridge IOAVServiceRef) cached;

    EZDDCLookup outcome;
    IOAVServiceRef service = CopyServiceForDisplay(display, &outcome);
    if (!service)
    {
        gServices[@(display)] = outcome == EZDDCLookupUnanswered ? Unanswered() : [NSNull null];
        return NULL;
    }

    // The dictionary holds the only reference from here on, so the returned
    // pointer is borrowed and stays valid until `invalidateCaches`.
    gServices[@(display)] = (__bridge id) service;
    CFRelease(service);
    return service;
}

// The two codes are cached apart: a monitor can implement volume and not mute.
static NSNumber *RangeKey(CGDirectDisplayID display, uint8_t vcp)
{
    return @(((uint64_t) display << 8) | vcp);
}

/// The display's own maximum for `vcp`, or 0 when it does not implement it.
///
/// This is also the gate on every write. Nothing is written to a code that has
/// not first come back from the display with a range, so a monitor that never
/// claimed to have speakers never receives a volume frame.
static int MaximumFor(CGDirectDisplayID display, uint8_t vcp)
{
    if (!gRanges)
        gRanges = [NSMutableDictionary dictionary];

    NSNumber *cached = gRanges[RangeKey(display, vcp)];
    const int previous = cached ? cached.intValue : EZDDCRangeUnknown;

    // A settled entry is the display's own answer and needs no exchange. An
    // unconfirmed one is a failed read, which is not an answer, so it falls
    // through and asks again.
    if (EZDDCRangeIsSettled(previous))
        return previous;

    IOAVServiceRef service = ServiceForDisplay(display);
    if (!service)
        return 0;

    const int remembered = EZDDCRangeToRemember(previous, ReadVCP(service, vcp));
    gRanges[RangeKey(display, vcp)] = @(remembered);

    // Unconfirmed reads as no range for this call, which is what a caller can
    // act on now, without the entry claiming the display said so.
    return EZDDCRangeIsSettled(remembered) ? remembered : 0;
}

/// The current raw value for a code known to be supported, or -1.
static int CurrentFor(CGDirectDisplayID display, uint8_t vcp)
{
    IOAVServiceRef service = ServiceForDisplay(display);
    if (!service)
        return -1;

    EZDDCReading reading = ReadVCP(service, vcp);
    return reading.answered() ? reading.current : -1;
}

/// Writes `value` and reports whether the display took it.
///
/// The range read comes first and is required rather than best effort: it is
/// rule 2, and a code that has never answered with a range never gets written
/// to. It is cached, so it costs an exchange once per display rather than once
/// per write.
///
/// There is no second read before the write. There was, to give the read-back
/// something to compare against, and comparing against it is what let a write
/// of 20 that landed on 0 report success. The read-back is now measured against
/// the value asked for, which needs no baseline — so the read is gone, and with
/// it a pair of frames on a bus slow enough for them to count.
static BOOL WriteAndVerify(CGDirectDisplayID display, uint8_t vcp, uint16_t value)
{
    IOAVServiceRef service = ServiceForDisplay(display);
    if (!service)
        return NO;

    const int maximum = MaximumFor(display, vcp);
    if (maximum <= 0)
        return NO;

    if (!WriteVCP(service, vcp, value))
        return NO;

    const int after = CurrentFor(display, vcp);
    if (after < 0)
        return NO;

    return EZDDCWriteTookEffect((int) value, after, maximum);
}

/// A volume percentage on the display's own scale, written and verified.
///
/// Shared by the blocking setter and the coalesced one so the two cannot drift
/// apart on the conversion, which is the step where a percentage meets a dial
/// that might run to 64 or 255.
static BOOL WriteVolume(CGDirectDisplayID display, int percent)
{
    const int maximum = MaximumFor(display, EZVCPSpeakerVolume);
    if (maximum <= 0)
        return NO;

    const int raw = EZDDCVolumeRawFromPercent(percent, maximum);
    return WriteAndVerify(display, EZVCPSpeakerVolume, (uint16_t) raw);
}

#pragma mark - EZDisplayAudio

@implementation EZDisplayAudio

+ (BOOL) supported
{
    ResolveSymbols();
    return gAVCreate != NULL && gAVRead != NULL && gAVWrite != NULL;
}

+ (BOOL) availableForDisplay: (CGDirectDisplayID) display
{
    __block BOOL available = NO;
    dispatch_sync(BusQueue(), ^{
        available = MaximumFor(display, EZVCPSpeakerVolume) > 0;
    });
    return available;
}

+ (NSInteger) percentForDisplay: (CGDirectDisplayID) display
{
    __block NSInteger percent = -1;
    dispatch_sync(BusQueue(), ^{
        const int maximum = MaximumFor(display, EZVCPSpeakerVolume);
        if (maximum <= 0)
            return;

        const int raw = CurrentFor(display, EZVCPSpeakerVolume);
        if (raw < 0)
            return;

        percent = EZDDCPercentFromRaw(raw, maximum);
    });
    return percent;
}

+ (BOOL) setPercent: (NSInteger) percent forDisplay: (CGDirectDisplayID) display
{
    __block BOOL applied = NO;
    dispatch_sync(BusQueue(), ^{
        applied = WriteVolume(display, (int) percent);
    });
    return applied;
}

+ (void) setPercentCoalesced: (NSInteger) percent
                  forDisplay: (CGDirectDisplayID) display
                  completion: (void (^)(BOOL applied)) completion
{
    NSNumber *key = RangeKey(display, EZVCPSpeakerVolume);

    // Recorded here, on the caller's thread, so it is in the mailbox before any
    // work item posted earlier has had its turn. That ordering is the whole
    // mechanism: see the note on `gWanted`.
    os_unfair_lock_lock(&gMailboxLock);
    if (!gWanted)
        gWanted = [NSMutableDictionary dictionary];
    gWanted[key] = @((int) percent);
    os_unfair_lock_unlock(&gMailboxLock);

    dispatch_async(BusQueue(), ^{
        os_unfair_lock_lock(&gMailboxLock);
        NSNumber *wanted  = gWanted[key];
        NSNumber *written = gWritten[key];
        const EZDDCPendingWrite next =
            EZDDCNextWrite(wanted  ? wanted.intValue  : EZDDCNoValue,
                           written ? written.intValue : EZDDCNoValue);
        // Marked as sent before it is sent, so the items queued behind this one
        // skip the value rather than each writing it again while it is on the
        // wire. A write that then fails is corrected by the read-back below.
        if (next.shouldWrite)
        {
            if (!gWritten)
                gWritten = [NSMutableDictionary dictionary];
            gWritten[key] = @(next.value);
        }
        os_unfair_lock_unlock(&gMailboxLock);

        if (!next.shouldWrite)
            return;

        const BOOL applied = WriteVolume(display, next.value);

        // The read-back stays even on a slider write. It costs a frame pair the
        // coalescing has already paid for, and it is the third of the safety
        // rules in the header — on this queue it costs no responsiveness,
        // because nothing here is on the main thread.
        if (!applied)
        {
            os_unfair_lock_lock(&gMailboxLock);
            [gWritten removeObjectForKey: key];
            os_unfair_lock_unlock(&gMailboxLock);
        }

        if (completion)
            dispatch_async(dispatch_get_main_queue(), ^{ completion(applied); });
    });
}

+ (BOOL) muteAvailableForDisplay: (CGDirectDisplayID) display
{
    __block BOOL available = NO;
    dispatch_sync(BusQueue(), ^{
        available = MaximumFor(display, EZVCPAudioMute) > 0;
    });
    return available;
}

+ (NSInteger) mutedForDisplay: (CGDirectDisplayID) display
{
    __block NSInteger muted = -1;
    dispatch_sync(BusQueue(), ^{
        if (MaximumFor(display, EZVCPAudioMute) <= 0)
            return;

        const int raw = CurrentFor(display, EZVCPAudioMute);
        if (raw < 0)
            return;

        // Anything that is not the code's own muted value counts as unmuted, so
        // a display reporting a third value is read as audible rather than as
        // an error a caller would have to interpret.
        muted = raw == EZDDCMuted ? 1 : 0;
    });
    return muted;
}

/// The mute write itself, on the bus queue, for both forms of it below.
static BOOL WriteMute(CGDirectDisplayID display, BOOL muted)
{
    if (MaximumFor(display, EZVCPAudioMute) <= 0)
        return NO;

    return WriteAndVerify(display, EZVCPAudioMute,
                          muted ? EZDDCMuted : EZDDCUnmuted);
}

+ (BOOL) setMuted: (BOOL) muted forDisplay: (CGDirectDisplayID) display
{
    __block BOOL applied = NO;
    dispatch_sync(BusQueue(), ^{
        applied = WriteMute(display, muted);
    });
    return applied;
}

+ (void) setMuted: (BOOL) muted
       forDisplay: (CGDirectDisplayID) display
       completion: (void (^)(BOOL applied)) completion
{
    dispatch_async(BusQueue(), ^{
        const BOOL applied = WriteMute(display, muted);
        if (completion)
            dispatch_async(dispatch_get_main_queue(), ^{ completion(applied); });
    });
}

+ (void) invalidateCaches
{
    dispatch_sync(BusQueue(), ^{ DropCaches(); });
}

+ (BOOL) awaitingAnswer
{
    __block BOOL awaiting = NO;
    dispatch_sync(BusQueue(), ^{
        std::vector<int> ranges;
        for (NSNumber *range in gRanges.allValues)
            ranges.push_back(range.intValue);
        awaiting = EZDDCRangesAwaitAnswer(ranges.data(), ranges.size())
                || [gServices allKeysForObject: Unanswered()].count > 0;
    });
    return awaiting;
}

// Set while a look is queued, so a burst of key presses asks the bus once.
static std::atomic<bool> gLookingAgain{false};

+ (void) lookAgainWhereUnanswered: (void (^)(void)) answered
{
    if (gLookingAgain.exchange(true))
        return;

    dispatch_async(BusQueue(), ^{
        BOOL settled = NO;

        for (NSNumber *display in [gServices allKeysForObject: Unanswered()])
        {
            [gServices removeObjectForKey: display];
            if (ServiceForDisplay(display.unsignedIntValue))
                settled = YES;
        }

        // Asked afresh rather than a second time. A second failure in a row
        // settles a code as absent, and this runs because someone wants the
        // volume now, on a bus that may still be failing.
        for (NSNumber *key in [gRanges allKeysForObject: @(EZDDCRangeUnconfirmed)])
        {
            [gRanges removeObjectForKey: key];
            const uint64_t packed = key.unsignedLongLongValue;
            MaximumFor((CGDirectDisplayID) (packed >> 8), (uint8_t) (packed & 0xFF));

            NSNumber *now = gRanges[key];
            if (now && EZDDCRangeIsSettled(now.intValue))
                settled = YES;
        }

        gLookingAgain = false;
        if (settled)
            dispatch_async(dispatch_get_main_queue(), answered);
    });
}

@end
