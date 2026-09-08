//
//  DDC.mm
//  EZDisplay
//

#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <unistd.h>

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

// AppleSiliconDDC's timings, kept because they are what is proven on Apple
// silicon rather than because the specification asks for them. Shortening any
// of them is not a tuning exercise: too little settle time returns the previous
// exchange's bytes, which pass a checksum and parse into a plausible setting.
//
// Together these put about 90 ms into every exchange, which is why the results
// are cached and why the header tells a slider to coalesce.
static const useconds_t kSettleBeforeWrite  = 10000;
static const useconds_t kSettleBeforeRead   = 50000;
static const useconds_t kSettleBetweenTries = 20000;

// The request goes twice. AppleSiliconDDC does this and displays in the wild
// need it: the first frame is dropped often enough that a single write reads
// back unchanged and looks like a display refusing the code.
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
static IOAVServiceRef CopyServiceForDisplay(CGDirectDisplayID display)
{
    NSString *portNode = EZPortNodeForDisplay(display);
    if (!portNode)
        return NULL;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("DCPAVServiceProxy"),
                                     &iter) != KERN_SUCCESS)
        return NULL;

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

                if (EZDDCReadingIsDefinite(probe))
                    chosen = candidate;
                else
                    CFRelease(candidate);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return chosen;
}

#pragma mark - Caches

// Both are keyed by display ID and both are dropped wholesale on
// reconfiguration, because after one a port may hold a different monitor.
static NSMutableDictionary<NSNumber *, id> *gServices;  // NSNull once looked for and absent
static NSMutableDictionary<NSNumber *, NSNumber *> *gRanges;  // 0 once known unsupported

static IOAVServiceRef ServiceForDisplay(CGDirectDisplayID display)
{
    ResolveSymbols();
    if (!gAVCreate || !gAVRead || !gAVWrite)
        return NULL;

    if (!gServices)
        gServices = [NSMutableDictionary dictionary];

    id cached = gServices[@(display)];
    if (cached == [NSNull null])
        return NULL;
    if (cached)
        return (__bridge IOAVServiceRef) cached;

    IOAVServiceRef service = CopyServiceForDisplay(display);
    if (!service)
    {
        gServices[@(display)] = [NSNull null];
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
/// it a pair of frames on a bus where MonitorControl puts none at all around a
/// write.
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

#pragma mark - EZDisplayAudio

@implementation EZDisplayAudio

+ (BOOL) supported
{
    ResolveSymbols();
    return gAVCreate != NULL && gAVRead != NULL && gAVWrite != NULL;
}

+ (BOOL) availableForDisplay: (CGDirectDisplayID) display
{
    return MaximumFor(display, EZVCPSpeakerVolume) > 0;
}

+ (NSInteger) percentForDisplay: (CGDirectDisplayID) display
{
    const int maximum = MaximumFor(display, EZVCPSpeakerVolume);
    if (maximum <= 0)
        return -1;

    const int raw = CurrentFor(display, EZVCPSpeakerVolume);
    if (raw < 0)
        return -1;

    return EZDDCPercentFromRaw(raw, maximum);
}

+ (BOOL) setPercent: (NSInteger) percent forDisplay: (CGDirectDisplayID) display
{
    const int maximum = MaximumFor(display, EZVCPSpeakerVolume);
    if (maximum <= 0)
        return NO;

    const int raw = EZDDCVolumeRawFromPercent((int) percent, maximum);
    return WriteAndVerify(display, EZVCPSpeakerVolume, (uint16_t) raw);
}

+ (BOOL) muteAvailableForDisplay: (CGDirectDisplayID) display
{
    return MaximumFor(display, EZVCPAudioMute) > 0;
}

+ (NSInteger) mutedForDisplay: (CGDirectDisplayID) display
{
    if (MaximumFor(display, EZVCPAudioMute) <= 0)
        return -1;

    const int raw = CurrentFor(display, EZVCPAudioMute);
    if (raw < 0)
        return -1;

    // Anything that is not the code's own muted value counts as unmuted, so a
    // display reporting a third value is read as audible rather than as an
    // error a caller would have to interpret.
    return raw == EZDDCMuted ? 1 : 0;
}

+ (BOOL) setMuted: (BOOL) muted forDisplay: (CGDirectDisplayID) display
{
    if (MaximumFor(display, EZVCPAudioMute) <= 0)
        return NO;

    return WriteAndVerify(display, EZVCPAudioMute, muted ? EZDDCMuted : EZDDCUnmuted);
}

+ (void) invalidateCaches
{
    gServices = nil;
    gRanges   = nil;
}

@end
