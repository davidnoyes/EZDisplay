//
//  ColorMode.mm
//  EZDisplay
//

#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

#import "ColorMode.h"
#import "DisplayPort.h"

// The colour-mode stack is entirely private and unversioned, so it is reached
// through dlsym rather than linked. Every symbol is optional: if one is
// missing, the accessors below return nil/empty and Preferences says colour
// mode is unavailable.

typedef CFTypeRef IOAVRef;
typedef IOAVRef     (*FnCreateWithService)(CFAllocatorRef, io_service_t);
typedef CFTypeRef   (*FnCopy)(IOAVRef);
typedef int         (*FnGetLinkData)(IOAVRef, void *);
// The counterpart to GetLinkData: it takes the same 256-byte structure back and
// restarts the link on it. Not a documented signature — the second argument is
// a struct rather than a scalar because the function hands IOConnectCallMethod
// an inputStructCnt of 0x100, which is exactly what GetLinkData writes.
typedef kern_return_t (*FnStartLink)(IOAVRef, const void *);
typedef const char *(*FnEnumString)(uint32_t);
typedef bool        (*FnHDRQuery)(CGDirectDisplayID);
typedef void        (*FnHDRSet)(CGDirectDisplayID, bool);

static FnCreateWithService gCreateWithService;
static FnCopy              gCopyColorElements;
static FnCopy              gCopyTimingElements;
static FnCopy              gCopyDisplayAttributes;
static FnGetLinkData       gGetLinkData;
static FnStartLink         gStartLink;
static FnEnumString        gEncodingString;
static FnEnumString        gRangeString;
static FnEnumString        gEOTFString;
static FnEnumString        gColorimetryString;
static FnHDRQuery          gSupportsHDR;
static FnHDRQuery          gIsHDREnabled;
static FnHDRSet            gSetHDREnabled;

// GetLinkData fills a struct describing the live link. Two of its fields are
// verbatim copies of the ElementData blobs the enumerations hand back, so the
// current timing and colour mode are identified by exact byte match rather
// than by interpreting any of the private enums.
//
// The call takes no length argument, so there is no way to tell it how much
// room it has: the buffer either fits the struct of the day or is silently
// overrun. Everything read lives below offset 120, and the buffer is far
// larger than that, but a future macOS could grow the struct. The tail below
// is therefore slack plus a sentinel, checked after every call — if a later OS
// writes past what we expect, colour mode reports itself unavailable instead
// of parsing corrupted memory.
static const size_t   kLinkDataSize     = 512;
static const size_t   kLinkDataUsed     = 256;  // beyond this is slack + sentinel
static const uint8_t  kLinkDataSentinel = 0xA5;
static const size_t   kColorDataOffset  = 8;
static const size_t   kColorDataSize    = 32;
static const size_t   kTimingDataOffset = 40;
static const size_t   kTimingDataSize   = 80;

static void ResolveSymbols(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);

        gCreateWithService     = (FnCreateWithService)dlsym(RTLD_DEFAULT, "IOAVVideoInterfaceCreateWithService");
        gCopyColorElements     = (FnCopy)dlsym(RTLD_DEFAULT, "IOAVVideoInterfaceCopyColorElements");
        gCopyTimingElements    = (FnCopy)dlsym(RTLD_DEFAULT, "IOAVVideoInterfaceCopyTimingElements");
        gCopyDisplayAttributes = (FnCopy)dlsym(RTLD_DEFAULT, "IOAVVideoInterfaceCopyDisplayAttributes");
        gGetLinkData           = (FnGetLinkData)dlsym(RTLD_DEFAULT, "IOAVVideoInterfaceGetLinkData");
        gStartLink             = (FnStartLink)dlsym(RTLD_DEFAULT, "IOAVVideoInterfaceStartLink");
        gEncodingString        = (FnEnumString)dlsym(RTLD_DEFAULT, "IOAVVideoPixelEncodingString");
        gRangeString           = (FnEnumString)dlsym(RTLD_DEFAULT, "IOAVVideoColorDynamicRangeString");
        gEOTFString            = (FnEnumString)dlsym(RTLD_DEFAULT, "IOAVVideoColorEOTFString");
        gColorimetryString     = (FnEnumString)dlsym(RTLD_DEFAULT, "IOAVVideoColorimetryString");
        gSupportsHDR           = (FnHDRQuery)dlsym(RTLD_DEFAULT, "CoreDisplay_Display_SupportsHDRMode");
        gIsHDREnabled          = (FnHDRQuery)dlsym(RTLD_DEFAULT, "CoreDisplay_Display_IsHDRModeEnabled");
        gSetHDREnabled         = (FnHDRSet)dlsym(RTLD_DEFAULT, "CoreDisplay_Display_SetHDRModeEnabled");
    });
}

static BOOL EnumerationAvailable(void)
{
    ResolveSymbols();
    return gCreateWithService && gCopyColorElements && gCopyTimingElements
        && gCopyDisplayAttributes && gGetLinkData
        && gEncodingString && gRangeString && gEOTFString && gColorimetryString;
}

// The one expensive call in this file, and by a long way: measured at 358 ms
// for a display advertising 60 timings, against 7 ms for everything else
// supportedForDisplay: does — finding the interface, reading the link, matching
// the current timing. Called on every open of the Color Mode submenu, it would
// be a third of a second of frozen menu each time.
//
// What it returns is the set of timings the display advertises, which is a
// property of the display and does not move: choosing a different resolution
// changes which one is *in force*, and that is read from the link data at a
// cost of about a millisecond. So the list is cached and the choice is not.
//
// Keyed on display ID, which is reused when one display replaces another, so
// the cache is dropped on reconfiguration rather than trusted to age out.
static NSMutableDictionary<NSNumber *, NSArray *> *gTimingCache;

static NSArray *CopyTimingElementsCached(CGDirectDisplayID display, IOAVRef iface)
{
    NSNumber *key = @(display);
    NSArray *cached = gTimingCache[key];
    if (cached)
        return cached;

    NSArray *timings = (__bridge_transfer NSArray *)gCopyTimingElements(iface);
    if (!timings)
        return nil;

    if (!gTimingCache)
        gTimingCache = [NSMutableDictionary dictionary];
    gTimingCache[key] = timings;
    return timings;
}

// Applying needs everything reading needs, plus the setter. Separate from
// EnumerationAvailable so a build of macOS that drops only StartLink still
// reports colour modes instead of hiding the whole section.
static BOOL ApplyAvailable(void)
{
    return EnumerationAvailable() && gStartLink != NULL;
}

static NSString *EnumName(FnEnumString fn, uint32_t value)
{
    const char *s = fn ? fn(value) : NULL;
    return s ? @(s) : [NSString stringWithFormat:@"%u", value];
}

// The EOTF enum is private and unversioned, so this matches Apple's own name
// for the value rather than a number read off one machine.
//
// EnumName falls back to the bare number, which matches neither test, so an
// unrecognised transfer function reads as SDR. That is the wrong way round for
// one caller taken alone — supportedForDisplay: drops a mode only when this
// says HDR, so an unrecognised HDR transfer stays on offer even where the
// system has ruled HDR out — and it is still the right default, because the
// unrecognised case is not per-value. If gEOTFString itself is missing, every
// value falls back to a number, every mode reads as HDR, and the list collapses
// to the single current row on any display where HDR is unavailable. Losing the
// whole list to a missing symbol is a worse failure than leaving one mode on
// offer, and the mode is one the display advertised for this timing either way.
static BOOL IsHDRTransfer(uint32_t eotf)
{
    NSString *name = EnumName(gEOTFString, eotf).uppercaseString;
    return [name containsString:@"2084"] || [name containsString:@"HLG"];
}


@interface EZColorMode ()
- (instancetype)initWithElement:(NSDictionary *)element isCurrent:(BOOL)isCurrent;
@end

@implementation EZColorMode

- (instancetype)initWithElement:(NSDictionary *)element isCurrent:(BOOL)isCurrent
{
    if ((self = [super init]))
    {
        _elementID     = [element[@"ID"] intValue];
        _bitDepth      = [element[@"Depth"] intValue];
        _pixelEncoding = [element[@"PixelEncoding"] unsignedIntValue];
        _dynamicRange  = [element[@"DynamicRange"] unsignedIntValue];
        _eotf          = [element[@"EOTF"] unsignedIntValue];
        _colorimetry   = [element[@"Colorimetry"] unsignedIntValue];
        _isCurrent     = isCurrent;
        _isDerived     = [element[@"IsVirtual"] boolValue];
        _isHDR         = IsHDRTransfer(_eotf);
        // Kept as separate strings as well as the joined label, so a caller can
        // lay the parts out as its own columns or badges. Apple's helpers are
        // the only names for these enums, and the numbers behind them are
        // unversioned, so deriving the parts by splitting the label back apart
        // would be guessing at a format we do not own.
        _pixelEncodingName = EnumName(gEncodingString, _pixelEncoding);
        _dynamicRangeName  = EnumName(gRangeString, _dynamicRange);
        _eotfName          = EnumName(gEOTFString, _eotf);
        _colorimetryName   = EnumName(gColorimetryString, _colorimetry);
        _label = [NSString stringWithFormat:@"%d-bit · %@ · %@ · %@ · %@",
                  _bitDepth,
                  _pixelEncodingName,
                  _dynamicRangeName,
                  _eotfName,
                  _colorimetryName];
    }
    return self;
}

@end


// The AV interface for a display, matched on the manufacturer and product IDs
// CoreGraphics reports. Returns a +1 reference, or NULL when there is no match
// — an internal panel, or a display driven by something other than the DCP AV
// path.
//
// Manufacturer and product are all there is to match on: the serial number is
// not reported consistently enough to break a tie. Two identical monitors
// therefore both match the same interfaces, and picking whichever the iterator
// yielded first would attribute one monitor's colour mode to the other with no
// sign anything was wrong. The whole iterator is drained so that case can be
// recognised, and an ambiguous match reports nothing rather than guessing.
//
// Several interfaces are not on their own evidence of several monitors: the DCP
// exposes a proxy per stream, and a 34" Philips presents two of them carrying
// byte-identical product attributes. See +matchIsAmbiguousWithInterfaces:, and
// +preferredMatchIndexWithLiveness: for which of them to then read from.

// Fills `linkData` with the live link description. NO if the interface will not
// report it, or if it wrote further than this build expects.
static BOOL ReadLinkData(IOAVRef iface, uint8_t *linkData)
{
    memset(linkData, 0, kLinkDataUsed);
    memset(linkData + kLinkDataUsed, kLinkDataSentinel, kLinkDataSize - kLinkDataUsed);
    if (gGetLinkData(iface, linkData) != 0)
        return NO;

    for (size_t i = kLinkDataUsed; i < kLinkDataSize; i++)
        if (linkData[i] != kLinkDataSentinel)
            return NO;   // struct outgrew this build's assumptions
    return YES;
}

// Whether this interface is the one attached to the live link. Defined as
// "ReadLinkData will work", since that is the only thing the choice affects.
static BOOL LinkIsLive(IOAVRef iface)
{
    uint8_t linkData[kLinkDataSize];
    return ReadLinkData(iface, linkData);
}

// How many online displays report this manufacturer and product.
static NSUInteger CountDisplaysSharingProduct(uint32_t vendor, uint32_t product)
{
    CGDirectDisplayID ids[32];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList((uint32_t)(sizeof(ids) / sizeof(ids[0])), ids, &count)
        != kCGErrorSuccess)
        return 0;

    NSUInteger sharing = 0;
    for (uint32_t i = 0; i < count; i++)
        if (CGDisplayVendorNumber(ids[i]) == vendor && CGDisplayModelNumber(ids[i]) == product)
            sharing++;
    return sharing;
}

static IOAVRef CopyAVInterfaceForDisplay(CGDirectDisplayID display)
{
    uint32_t wantVendor  = CGDisplayVendorNumber(display);
    uint32_t wantProduct = CGDisplayModelNumber(display);

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("DCPAVVideoInterfaceProxy"),
                                     &iter) != KERN_SUCCESS)
        return NULL;

    // nil on anything this does not recognise, which costs only the fallback to
    // matching on product alone.
    NSString *portNode = EZPortNodeForDisplay(display);

    // Held by the array, which keeps every candidate alive until one is chosen.
    NSMutableArray *matched = [NSMutableArray array];
    NSMutableArray<NSNumber *> *liveness = [NSMutableArray array];
    NSMutableArray<NSNumber *> *onPort   = [NSMutableArray array];

    io_service_t service;
    while ((service = IOIteratorNext(iter)))
    {
        IOAVRef iface = gCreateWithService(kCFAllocatorDefault, service);
        if (iface)
        {
            NSDictionary *attrs =
                (__bridge_transfer NSDictionary *)gCopyDisplayAttributes(iface);
            NSDictionary *product = attrs[@"ProductAttributes"];
            if ([product[@"LegacyManufacturerID"] unsignedIntValue] == wantVendor &&
                [product[@"ProductID"] unsignedIntValue] == wantProduct)
            {
                [matched addObject:(__bridge id)iface];
                [liveness addObject:@(LinkIsLive(iface))];
                [onPort addObject:@(portNode && EZServiceIsOnPort(service, portNode))];
            }
            CFRelease(iface);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    NSUInteger chosen =
        [EZColorModes preferredMatchIndexOnPort:onPort
                                       liveness:liveness
                                sharingDisplays:CountDisplaysSharingProduct(wantVendor,
                                                                            wantProduct)];
    if (chosen == NSNotFound)
        return NULL;

    return (IOAVRef)CFRetain((__bridge CFTypeRef)matched[chosen]);
}

// The element in `elements` whose ElementData matches `bytes` exactly.
static NSDictionary *ElementMatching(NSArray *elements, const uint8_t *bytes, size_t length)
{
    for (NSDictionary *element in elements)
    {
        NSData *data = element[@"ElementData"];
        if (data.length == length && memcmp(data.bytes, bytes, length) == 0)
            return element;
    }
    return nil;
}


@interface EZColorModeRestorePoint ()
@property (nonatomic) CGDirectDisplayID display;
@property (nonatomic, copy) NSData *colorData;
@property (nonatomic) BOOL hdrEnabled;
@end

@implementation EZColorModeRestorePoint
@end


// Puts macOS's HDR mode where a colour mode needs it, and waits for the link to
// say so.
//
// The two are separate pieces of state and only one of them is ours. HDR mode is
// what the compositor renders — SetHDRModeEnabled moves it, and macOS reconfigures
// the link to match as a side effect. A colour mode is the wire format alone:
// StartLink changes what the cable carries and tells the compositor nothing.
//
// Set one without the other and they disagree. Measured: with HDR enabled,
// applying an SDR-gamma colour mode left the link on SDR gamma and
// IsHDRModeEnabled still reporting 1 — so the compositor went on emitting PQ
// while the cable declared plain gamma, and the display decoded one as the
// other. That is the "colours are way off" case, and it is not a display fault.
//
// So the transfer function is not independently choosable: it belongs to the HDR
// mode. Asking for a PQ colour mode is asking for HDR, and this grants it before
// the link is touched, rather than leaving the two to contradict each other.
//
// Waits by polling, because the link reports the change about 30 ms later —
// measured across six transitions, 24 to 38 ms — and a fixed sleep would be
// either a guess that is too short or a stall that is mostly waste. Gives up
// after two seconds and lets the caller apply anyway: the worst case is the
// disagreement that was there before this function existed.
static void SetHDRAndSettle(CGDirectDisplayID display, BOOL wanted)
{
    if (!gSetHDREnabled || !gIsHDREnabled)
        return;
    gSetHDREnabled(display, wanted);

    for (int i = 0; i < 40; i++)
    {
        EZColorMode *now = [EZColorModes currentForDisplay:display];
        if (now && now.isHDR == wanted)
            return;
        usleep(50 * 1000);
    }
}


// The colour element with this ID at the timing now in force, or nil. Separate
// from applying it because the answer is needed twice: once to find out whether
// the mode wants HDR, and again after the HDR change, since that reconfigures
// the link and the bytes have to be read against where it ended up.
static NSDictionary *ElementWithID(CGDirectDisplayID display, int elementID)
{
    IOAVRef iface = CopyAVInterfaceForDisplay(display);
    if (!iface)
        return nil;

    NSDictionary *found = nil;
    uint8_t linkData[kLinkDataSize];
    if (ReadLinkData(iface, linkData))
    {
        NSArray *timings = CopyTimingElementsCached(display, iface);
        NSDictionary *timing = ElementMatching(timings, linkData + kTimingDataOffset,
                                               kTimingDataSize);
        for (NSDictionary *element in timing[@"ColorModes"])
            if ([element[@"ID"] intValue] == elementID)
                found = element;
    }
    CFRelease(iface);
    return found;
}


// The write path. Everything above reads; this restarts the display link.
//
// GetLinkData returns a 256-byte description of the live link, and StartLink
// takes the same 256 bytes back — one structure, read one way and written the
// other. Changing colour mode is therefore that round trip with the 32-byte
// colour blob swapped for another element's, and reverting is the same call
// again with the blob the link was running before. There is no second
// mechanism, which is the whole reason this can sit behind a confirm-or-revert
// prompt honestly.
//
// The one guard that matters lives here rather than at the call site: the
// element must appear in the list the display reports for the timing in force
// *at this moment*. An element valid at some other timing is exactly the kind
// the link might not come back from. Checking it here also covers reverting —
// if the resolution changed while a confirmation was still on screen, macOS has
// already picked a colour element for the new timing, and forcing the old one
// back would be fighting the system over something it owns.
static EZColorModeChangeResult ApplyColorElementData(CGDirectDisplayID display,
                                                      NSData *colorData)
{
    // Everything before the timing check is a fault, not a supersession: the
    // symbols went missing, the display could not be matched or was ambiguous
    // between two identical monitors, or the link would not describe itself.
    // None of those mean the system has taken the decision away from us.
    if (!ApplyAvailable() || colorData.length != kColorDataSize)
        return EZColorModeChangeFailed;

    IOAVRef iface = CopyAVInterfaceForDisplay(display);
    if (!iface)
        return EZColorModeChangeFailed;

    EZColorModeChangeResult result = EZColorModeChangeFailed;
    uint8_t linkData[kLinkDataSize];
    if (ReadLinkData(iface, linkData))
    {
        NSArray *timings = CopyTimingElementsCached(display, iface);
        NSDictionary *timing = ElementMatching(timings, linkData + kTimingDataOffset,
                                               kTimingDataSize);
        if (!ElementMatching(timing[@"ColorModes"], (const uint8_t *)colorData.bytes,
                             kColorDataSize))
            result = EZColorModeChangeSuperseded;
        // Already running it: nothing to restart, and reporting success is
        // right — the link is in the state the caller asked for. Blanking the
        // display to arrive where it already is would be worse than useless on
        // the revert path, where it is the common case.
        else if (memcmp(linkData + kColorDataOffset, colorData.bytes, kColorDataSize) == 0)
            result = EZColorModeChangeApplied;
        else
        {
            memcpy(linkData + kColorDataOffset, colorData.bytes, kColorDataSize);
            result = gStartLink(iface, linkData) == KERN_SUCCESS
                   ? EZColorModeChangeApplied : EZColorModeChangeFailed;
        }
    }
    CFRelease(iface);
    return result;
}


@implementation EZColorModes

+ (BOOL)matchIsAmbiguousWithInterfaces:(NSUInteger)matchingInterfaces
                       sharingDisplays:(NSUInteger)displaysWithSameProduct
{
    // One interface leaves nothing to choose between, however many displays
    // share the product. Several interfaces are only a problem when there is
    // more than one display they could belong to; otherwise they are one
    // monitor the DCP has exposed more than once.
    //
    // A zero display count means CGGetOnlineDisplayList failed. That is not
    // evidence of a second monitor, and disabling colour mode on the strength
    // of an unrelated error would be the wrong way to be wrong.
    return matchingInterfaces > 1 && displaysWithSameProduct > 1;
}

+ (NSUInteger)preferredMatchIndexWithLiveness:(NSArray<NSNumber *> *)liveness
{
    for (NSUInteger i = 0; i < liveness.count; i++)
        if (liveness[i].boolValue)
            return i;
    return liveness.count ? 0 : NSNotFound;
}

+ (NSUInteger)preferredMatchIndexOnPort:(NSArray<NSNumber *> *)onPort
                               liveness:(NSArray<NSNumber *> *)liveness
                        sharingDisplays:(NSUInteger)displaysWithSameProduct
{
    // The port is definitive where it is known, so the candidates on it are the
    // only ones considered and there is nothing left to be ambiguous about.
    NSMutableArray<NSNumber *> *livenessOnPort = [NSMutableArray array];
    NSMutableArray<NSNumber *> *indices        = [NSMutableArray array];
    for (NSUInteger i = 0; i < onPort.count; i++)
        if (onPort[i].boolValue)
        {
            [livenessOnPort addObject:liveness[i]];
            [indices addObject:@(i)];
        }

    if (indices.count)
        return indices[[self preferredMatchIndexWithLiveness:livenessOnPort]].unsignedIntegerValue;

    // No interface carries the port, so this is the product match alone and it
    // has to fail closed for two of the same monitor exactly as it did before.
    if ([self matchIsAmbiguousWithInterfaces:liveness.count
                             sharingDisplays:displaysWithSameProduct])
        return NSNotFound;

    return [self preferredMatchIndexWithLiveness:liveness];
}

+ (void)invalidateCaches
{
    gTimingCache = nil;
}

+ (BOOL)shouldOfferMode:(BOOL)modeIsHDR
           hdrAvailable:(BOOL)hdrAvailable
              isCurrent:(BOOL)isCurrent
{
    return !modeIsHDR || hdrAvailable || isCurrent;
}

+ (BOOL)shouldChangeHDRTo:(BOOL)wanted
                     from:(BOOL)current
             hdrAvailable:(BOOL)hdrAvailable
{
    return hdrAvailable && wanted != current;
}

+ (nullable EZColorMode *)currentForDisplay:(CGDirectDisplayID)display
{
    if (!EnumerationAvailable())
        return nil;

    IOAVRef iface = CopyAVInterfaceForDisplay(display);
    if (!iface)
        return nil;

    EZColorMode *result = nil;
    uint8_t linkData[kLinkDataSize];
    if (ReadLinkData(iface, linkData))
    {
        // Matched against every element the display advertises, not just those
        // valid at the current timing, so the active mode is still reported if
        // the timing itself cannot be identified.
        NSArray *elements = (__bridge_transfer NSArray *)gCopyColorElements(iface);
        NSDictionary *current = ElementMatching(elements, linkData + kColorDataOffset,
                                                kColorDataSize);
        if (current)
            result = [[EZColorMode alloc] initWithElement:current isCurrent:YES];
    }
    CFRelease(iface);
    return result;
}

+ (NSArray<EZColorMode *> *)supportedForDisplay:(CGDirectDisplayID)display
{
    if (!EnumerationAvailable())
        return @[];

    IOAVRef iface = CopyAVInterfaceForDisplay(display);
    if (!iface)
        return @[];

    NSMutableArray<EZColorMode *> *result = [NSMutableArray array];
    uint8_t linkData[kLinkDataSize];
    if (ReadLinkData(iface, linkData))
    {
        // Valid combinations depend on the timing in force: the display-wide
        // element list includes modes this timing has no bandwidth for. Take
        // the current timing's own list instead.
        NSArray *timings = CopyTimingElementsCached(display, iface);
        NSDictionary *timing = ElementMatching(timings, linkData + kTimingDataOffset,
                                               kTimingDataSize);
        NSData *currentColorData = [NSData dataWithBytes:linkData + kColorDataOffset
                                                  length:kColorDataSize];
        // IsVirtual entries are kept. They look like placeholders — low element
        // IDs, absent from what the display advertises — but on the test
        // display the only 12-bit HDR modes are flagged this way. Dropping them
        // would hide real options; they are marked instead.
        // Read once rather than per element: it is the same display throughout,
        // and it is a call into CoreDisplay.
        BOOL hdrAvailable = [self supportsHDRForDisplay:display];
        for (NSDictionary *element in timing[@"ColorModes"])
        {
            BOOL isCurrent = [element[@"ElementData"] isEqualToData:currentColorData];
            EZColorMode *mode = [[EZColorMode alloc] initWithElement:element
                                                           isCurrent:isCurrent];
            if ([self shouldOfferMode:mode.isHDR
                         hdrAvailable:hdrAvailable
                            isCurrent:isCurrent])
                [result addObject:mode];
        }
    }
    CFRelease(iface);
    return result;
}

+ (nullable NSString *)productNameForDisplay:(CGDirectDisplayID)display
{
    if (!EnumerationAvailable())
        return nil;

    IOAVRef iface = CopyAVInterfaceForDisplay(display);
    if (!iface)
        return nil;
    NSDictionary *attrs = (__bridge_transfer NSDictionary *)gCopyDisplayAttributes(iface);
    CFRelease(iface);

    // The internal panel has an interface and reports no name on it, so an empty
    // string has to read as "no name" rather than becoming one.
    NSString *name = attrs[@"ProductAttributes"][@"ProductName"];
    return name.length > 0 ? name : nil;
}

+ (BOOL)supportsHDRForDisplay:(CGDirectDisplayID)display
{
    ResolveSymbols();
    return gSupportsHDR ? gSupportsHDR(display) : NO;
}

+ (BOOL)isHDREnabledForDisplay:(CGDirectDisplayID)display
{
    ResolveSymbols();
    return gIsHDREnabled ? gIsHDREnabled(display) : NO;
}

+ (BOOL)setHDREnabled:(BOOL)enabled forDisplay:(CGDirectDisplayID)display
{
    ResolveSymbols();
    // Gated on the display's own capability rather than tried and checked: the
    // call returns nothing, so a display that cannot do HDR would fail silently.
    if (!gSetHDREnabled || !gSupportsHDR || !gSupportsHDR(display))
        return NO;

    gSetHDREnabled(display, enabled);
    return YES;
}

+ (nullable EZColorModeRestorePoint *)applyElementID:(int)elementID
                                            toDisplay:(CGDirectDisplayID)display
{
    if (!ApplyAvailable())
        return nil;

    IOAVRef iface = CopyAVInterfaceForDisplay(display);
    if (!iface)
        return nil;

    // Resolve the ID against the current timing's own list, and capture what
    // the link is running now in the same pass, so the two cannot disagree
    // about which timing they were read under.
    //
    // ApplyColorElementData then reads the link a second time, which looks
    // redundant and is not. This pass exists to turn an element ID into bytes,
    // which the helper cannot do — the revert path hands it bytes and has no ID
    // to offer. The helper's own read is the authoritative one, taken at the
    // moment of the write, and collapsing the two would mean trusting this
    // snapshot instead. Against a call that blanks the screen for a second, a
    // spare GetLinkData costs nothing worth having.
    NSData *wanted = nil, *previous = nil;
    BOOL wantsHDR = NO;
    uint8_t linkData[kLinkDataSize];
    if (ReadLinkData(iface, linkData))
    {
        previous = [NSData dataWithBytes:linkData + kColorDataOffset length:kColorDataSize];
        NSArray *timings = CopyTimingElementsCached(display, iface);
        NSDictionary *timing = ElementMatching(timings, linkData + kTimingDataOffset,
                                               kTimingDataSize);
        for (NSDictionary *element in timing[@"ColorModes"])
            if ([element[@"ID"] intValue] == elementID)
            {
                wanted   = element[@"ElementData"];
                wantsHDR = IsHDRTransfer([element[@"EOTF"] unsignedIntValue]);
            }
    }
    CFRelease(iface);

    if (!wanted || !previous || [wanted isEqualToData:previous])
        return nil;

    // Captured before anything moves, because reverting has to undo both halves
    // and the HDR half is what macOS will change the colour mode from underneath
    // us if it is left disagreeing.
    BOOL previousHDR  = [self isHDREnabledForDisplay:display];
    BOOL hdrAvailable = [self supportsHDRForDisplay:display];
    BOOL movingHDR    = [self shouldChangeHDRTo:wantsHDR
                                           from:previousHDR
                                   hdrAvailable:hdrAvailable];

    // Needed and impossible, which is the one combination that must not fall
    // through to the write. A mode whose transfer function wants the other HDR
    // state, on a display that cannot reach it, has no coherent form: applying
    // the wire format on its own is exactly the disagreement this function
    // exists to prevent, so refuse instead and let the caller say so.
    //
    // Reachable from a stale menu — the list was built while HDR was available
    // and the resolution has moved since. Not from a fresh one, because
    // shouldOfferMode: only offers an unavailable HDR mode when it is the one
    // already running, and applying that returns above as a no-op.
    if (wantsHDR != previousHDR && !movingHDR)
        return nil;

    // The transfer function belongs to macOS's HDR mode, not to the wire format
    // — see SetHDRAndSettle. Asking for a PQ mode is asking for HDR, so grant it
    // first; asking for a gamma mode is asking for HDR off, so take it away.
    // Applying the wire format alone is what made the colours wrong.
    if (movingHDR)
    {
        SetHDRAndSettle(display, wantsHDR);

        // macOS reconfigured the link on its way through, so the element has to
        // be found again against the timing it left behind. Same ID, and on the
        // test display the same bytes, but that is not something to assume of a
        // list that is per-timing by definition.
        NSDictionary *again = ElementWithID(display, elementID);
        if (again[@"ElementData"])
            wanted = again[@"ElementData"];
    }

    // Often a no-op by the time it runs, and rightly so: the HDR change lands on
    // each state's default colour mode, which is usually the one being asked
    // for. ApplyColorElementData reports that as applied without restarting the
    // link, so the display is not blanked twice to arrive where it already is.
    EZColorModeChangeResult result = ApplyColorElementData(display, wanted);
    if (result != EZColorModeChangeApplied)
    {
        // Put the HDR mode back rather than leave it moved for a colour mode
        // that never took. Half a change is the state this whole function
        // exists to avoid.
        //
        // Superseded is undone here too, though elsewhere it is the blameless
        // outcome nobody should reverse. The difference is that this path also
        // returns nil, so there is no restore point, no confirm panel, and no
        // way back: leaving HDR moved would move it silently and permanently
        // for a colour mode the user never got. Changing nothing is the honest
        // report of having changed nothing.
        if (movingHDR)
            SetHDRAndSettle(display, previousHDR);
        return nil;
    }

    EZColorModeRestorePoint *point = [[EZColorModeRestorePoint alloc] init];
    point.display = display;
    point.colorData = previous;
    point.hdrEnabled = previousHDR;
    return point;
}

+ (EZColorModeChangeResult)restore:(EZColorModeRestorePoint *)point
{
    if (!point)
        return EZColorModeChangeFailed;

    BOOL currentHDR = [self isHDREnabledForDisplay:point.display];
    BOOL movingHDR  = [self shouldChangeHDRTo:point.hdrEnabled
                                         from:currentHDR
                                 hdrAvailable:[self supportsHDRForDisplay:point.display]];

    // The undo wants an HDR state the display can no longer reach, so there is
    // no coherent half of it to put back. Twenty seconds is long enough for the
    // resolution to have moved and taken HDR with it, and when it has, macOS has
    // already chosen a colour element to suit — which is Superseded's meaning
    // exactly, and why this reports it rather than a fault.
    if (point.hdrEnabled != currentHDR && !movingHDR)
        return EZColorModeChangeSuperseded;

    // HDR first and the colour mode second, the same order the apply used. The
    // HDR change moves the colour mode on its own, so doing it the other way
    // round would undo the restore that had just been made.
    if (movingHDR)
        SetHDRAndSettle(point.display, point.hdrEnabled);

    EZColorModeChangeResult result = ApplyColorElementData(point.display, point.colorData);

    // And symmetrically with the apply: an undo whose colour half did not take
    // is not an undo, so do not leave the HDR half moved on its own.
    if (result != EZColorModeChangeApplied && movingHDR)
        SetHDRAndSettle(point.display, currentHDR);

    return result;
}

@end
