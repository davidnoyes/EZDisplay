//
//  ColorMode.mm
//  EZDisplay
//

#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

#import "ColorMode.h"

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
static IOAVRef CopyAVInterfaceForDisplay(CGDirectDisplayID display)
{
    uint32_t wantVendor  = CGDisplayVendorNumber(display);
    uint32_t wantProduct = CGDisplayModelNumber(display);

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("DCPAVVideoInterfaceProxy"),
                                     &iter) != KERN_SUCCESS)
        return NULL;

    IOAVRef match = NULL;
    BOOL ambiguous = NO;
    io_service_t service;
    while ((service = IOIteratorNext(iter)))
    {
        IOAVRef iface = gCreateWithService(kCFAllocatorDefault, service);
        if (iface)
        {
            NSDictionary *attrs =
                (__bridge_transfer NSDictionary *)gCopyDisplayAttributes(iface);
            NSDictionary *product = attrs[@"ProductAttributes"];
            BOOL matches = [product[@"LegacyManufacturerID"] unsignedIntValue] == wantVendor &&
                           [product[@"ProductID"] unsignedIntValue] == wantProduct;
            if (matches && !match)
            {
                match = iface;
            }
            else
            {
                if (matches) ambiguous = YES;
                CFRelease(iface);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    if (ambiguous)
    {
        CFRelease(match);
        return NULL;
    }
    return match;
}

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
@end

@implementation EZColorModeRestorePoint
@end


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
        NSArray *timings = (__bridge_transfer NSArray *)gCopyTimingElements(iface);
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
        NSArray *timings = (__bridge_transfer NSArray *)gCopyTimingElements(iface);
        NSDictionary *timing = ElementMatching(timings, linkData + kTimingDataOffset,
                                               kTimingDataSize);
        NSData *currentColorData = [NSData dataWithBytes:linkData + kColorDataOffset
                                                  length:kColorDataSize];
        // IsVirtual entries are kept. They look like placeholders — low element
        // IDs, absent from what the display advertises — but BetterDisplay
        // offers them as selectable connection modes, and on the test display
        // the only 12-bit HDR modes are flagged this way. Dropping them would
        // hide real options; they are marked instead.
        for (NSDictionary *element in timing[@"ColorModes"])
        {
            BOOL isCurrent = [element[@"ElementData"] isEqualToData:currentColorData];
            [result addObject:[[EZColorMode alloc] initWithElement:element
                                                          isCurrent:isCurrent]];
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
    uint8_t linkData[kLinkDataSize];
    if (ReadLinkData(iface, linkData))
    {
        previous = [NSData dataWithBytes:linkData + kColorDataOffset length:kColorDataSize];
        NSArray *timings = (__bridge_transfer NSArray *)gCopyTimingElements(iface);
        NSDictionary *timing = ElementMatching(timings, linkData + kTimingDataOffset,
                                               kTimingDataSize);
        for (NSDictionary *element in timing[@"ColorModes"])
            if ([element[@"ID"] intValue] == elementID)
                wanted = element[@"ElementData"];
    }
    CFRelease(iface);

    if (!wanted || !previous || [wanted isEqualToData:previous])
        return nil;
    if (ApplyColorElementData(display, wanted) != EZColorModeChangeApplied)
        return nil;

    EZColorModeRestorePoint *point = [[EZColorModeRestorePoint alloc] init];
    point.display = display;
    point.colorData = previous;
    return point;
}

+ (EZColorModeChangeResult)restore:(EZColorModeRestorePoint *)point
{
    return point ? ApplyColorElementData(point.display, point.colorData)
                 : EZColorModeChangeFailed;
}

@end


// Both enums are private and unversioned, so these match Apple's own name for
// the value rather than a number read off one machine — the same approach the
// badges in Preferences take. EnumName falls back to the bare number, which
// matches neither test, so an unrecognised value fails both closed.
static BOOL IsHDRTransfer(uint32_t eotf)
{
    NSString *name = EnumName(gEOTFString, eotf).uppercaseString;
    return [name containsString:@"2084"] || [name containsString:@"HLG"];
}

static BOOL IsFullColorEncoding(uint32_t encoding)
{
    return [EnumName(gEncodingString, encoding).uppercaseString hasPrefix:@"RGB"];
}

// What one link timing can do for HDR, judged the way the bandwidth wall shows
// up: an element the timing lists is reachable, an element in
// DSCRequiredColorElementIDs is reachable only with the link compressed, and
// one in UnsafeColorElementIDs is not offered at all.
//
// DSCRequired means "needs compression", not "unavailable" — measured on the
// test display, which runs 3440 × 1440 at 175 Hz in 10-bit PQ with macOS
// engaging DSC to fit it.
static EZHDRFit FitForTiming(NSDictionary *timing)
{
    NSSet *needsDSC  = [NSSet setWithArray:timing[@"DSCRequiredColorElementIDs"] ?: @[]];
    NSSet *unsafeIDs = [NSSet setWithArray:timing[@"UnsafeColorElementIDs"] ?: @[]];

    BOOL anyHDR = NO, fullFree = NO, fullDSC = NO;
    for (NSDictionary *element in timing[@"ColorModes"])
    {
        if (!IsHDRTransfer([element[@"EOTF"] unsignedIntValue])) continue;
        if ([unsafeIDs containsObject:element[@"ID"]]) continue;
        anyHDR = YES;
        if (!IsFullColorEncoding([element[@"PixelEncoding"] unsignedIntValue])) continue;
        if ([element[@"Depth"] intValue] < 10) continue;
        if ([needsDSC containsObject:element[@"ID"]]) fullDSC = YES;
        else                                          fullFree = YES;
    }

    if (fullFree) return EZHDRFitFull;
    if (fullDSC)  return EZHDRFitCompressed;
    if (anyHDR)   return EZHDRFitReduced;
    return EZHDRFitNone;
}


@interface EZHDRFitMap ()
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *byGeometry;    // "WxH@Hz" -> EZHDRFit
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *nativeByRate;  // Hz       -> EZHDRFit
@end

// Building a map is one IOAVVideoInterfaceCopyTimingElements call, and that call
// was measured at 360–370 ms on the test display — near enough the entire cost of
// the scan, with the service enumeration and the attribute reads around it coming
// to under 10 ms between them. Long enough to be felt: refreshStatusMenu rebuilds
// the whole menu on every display reconfiguration, which arrives more than once
// for a single resolution change, and Preferences rebuilds on top of that. The
// answer was the same every time, because the timing list is what the display
// advertises rather than what it is running.
//
// Keyed by identity and not by display ID alone, because macOS recycles IDs: the
// map built for the monitor that used to be display 2 must not answer for the one
// that is display 2 now. A mismatch simply misses and rebuilds. The native size
// is in the key for the same reason — it shapes the map's fallback table, so a
// map built without one cannot answer for a caller that has one.
//
// Main thread only, like every caller and like the rest of this file.
//
// NSNull is "asked, and the answer was nothing", which has to be cached as
// firmly as a map: the display that reports an unusable timing list has already
// paid the 370 ms to find that out, and would pay it again on every rebuild.
static NSMutableDictionary<NSString *, id> *sMapCache;

@implementation EZHDRFitMap

+ (nullable instancetype)mapForDisplay:(CGDirectDisplayID)display
                           nativeWidth:(int)nativeWidth
                          nativeHeight:(int)nativeHeight
{
    NSString *cacheKey = [NSString stringWithFormat:@"%u/%u/%u/%dx%d",
                          display, CGDisplayVendorNumber(display),
                          CGDisplayModelNumber(display), nativeWidth, nativeHeight];
    if (!sMapCache)
        sMapCache = [NSMutableDictionary dictionary];
    id cached = sMapCache[cacheKey];
    if (cached)
        return cached == [NSNull null] ? nil : cached;

    if (!EnumerationAvailable())
        return nil;

    // The two nils above this line are not cached and need not be: neither has
    // reached the expensive call, and a display with no AV interface — the
    // internal panel — costs only the service enumeration, measured at under a
    // millisecond. Past this point every exit is cached, including the empty
    // one below.
    IOAVRef iface = CopyAVInterfaceForDisplay(display);
    if (!iface)
        return nil;
    NSArray *timings = (__bridge_transfer NSArray *)gCopyTimingElements(iface);
    CFRelease(iface);

    NSMutableDictionary<NSString *, NSNumber *> *byGeometry = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *nativeByRate = [NSMutableDictionary dictionary];

    for (NSDictionary *timing in timings)
    {
        int    width  = [timing[@"HorizontalAttributes"][@"Active"] intValue];
        int    height = [timing[@"VerticalAttributes"][@"Active"] intValue];
        // 16.16 fixed point: 3932160 / 65536 = 60.
        double rate   = [timing[@"VerticalAttributes"][@"SyncRate"] doubleValue] / 65536.0;
        if (width <= 0 || height <= 0 || rate < 1)
            continue;
        int hz = (int)lround(rate);

        // Several timings can share a geometry and a rate — 20 of the test
        // display's 60 are such duplicates. Which of them macOS picks is not
        // knowable from here, so the lowest wins: the enum runs worst to best.
        //
        // This is the lesser error, not a free one. If the duplicates disagree
        // and macOS picks the better, a row that really does carry HDR shows
        // nothing — wrong, and invisibly so. But the other direction promises
        // HDR the link then fails to deliver, which is worse to be told. The
        // test display's duplicates all agree, so neither case has been seen;
        // this is a judgement about which way to be wrong, not a measurement.
        NSNumber *fit = @(FitForTiming(timing));
        NSString *key = [NSString stringWithFormat:@"%dx%d@%d", width, height, hz];
        NSNumber *seen = byGeometry[key];
        if (!seen || fit.integerValue < seen.integerValue)
            byGeometry[key] = fit;

        if (nativeWidth > 0 && width == nativeWidth && height == nativeHeight)
        {
            NSNumber *seenNative = nativeByRate[@(hz)];
            if (!seenNative || fit.integerValue < seenNative.integerValue)
                nativeByRate[@(hz)] = fit;
        }
    }

    // An empty map is not a map of a display with no HDR — it is a display that
    // told us nothing, which is the case this method promises to answer with
    // nil. Returning the empty object instead would satisfy the caller's
    // "do we have a map?" test and then answer Unknown for every row, which is
    // precisely the column of a thousand dashes hiding the column exists to
    // avoid. Covers a NULL timing list as well as one whose entries are all
    // unusable.
    if (byGeometry.count == 0)
    {
        sMapCache[cacheKey] = [NSNull null];
        return nil;
    }

    EZHDRFitMap *map = [[EZHDRFitMap alloc] init];
    map.byGeometry   = byGeometry;
    map.nativeByRate = nativeByRate;
    sMapCache[cacheKey] = map;
    return map;
}

+ (void)invalidateCaches
{
    [sMapCache removeAllObjects];
}

// The desktop mode a user picks is not the signal the cable carries: macOS
// negotiates a link timing for it. The rule was measured rather than found
// documented — nothing cross-references a CoreGraphics mode to an IOAV timing,
// and CGDisplayModeGetIODisplayModeID is a dense sequence unrelated to the
// timing IDs. Five desktop modes were set on a 34" Philips and the live link
// read back each time:
//
//   desktop  800 × 600  (px  800 × 600)  @ 100 -> link  800 × 600  @ 100
//   desktop  960 × 540  (px 1920 × 1080) @ 120 -> link 1920 × 1080 @ 120
//   desktop 1256 × 526  (px 2511 × 1051) @  60 -> link 3440 × 1440 @  60
//   desktop  800 × 600  (px 1600 × 1200) @ 175 -> link 3440 × 1440 @ 175
//   desktop 2752 × 1152 (px 5504 × 2304) @ 120 -> link 3440 × 1440 @ 120
//
// So: the timing whose active geometry equals the mode's pixel dimensions at
// the same rate, and where there is none, the *native* timing at that rate.
// Native, not the largest — the third case had a 5120 × 2880 timing available
// at 60 Hz and did not use it.
- (EZHDRFit)fitForPixelWidth:(int)width height:(int)height refreshRate:(int)refreshRate
{
    // A mode that does not state a rate cannot be resolved to a timing, and
    // every rate here is a whole number of Hz on both sides.
    if (refreshRate <= 0)
        return EZHDRFitUnknown;

    NSString *key = [NSString stringWithFormat:@"%dx%d@%d", width, height, refreshRate];
    NSNumber *exact = _byGeometry[key];
    if (exact)
        return (EZHDRFit)exact.integerValue;

    NSNumber *fallback = _nativeByRate[@(refreshRate)];
    return fallback ? (EZHDRFit)fallback.integerValue : EZHDRFitUnknown;
}

+ (nullable NSString *)badgeForFit:(EZHDRFit)fit
{
    switch (fit)
    {
        case EZHDRFitFull:       return @"HDR";
        case EZHDRFitCompressed: return @"HDR (DSC)";
        case EZHDRFitReduced:    return @"HDR (reduced)";
        // Two different silences, and they must not look alike. A dash says EZDisplay
        // could not work out which link timing the mode would negotiate, so it
        // has no answer; nothing at all says the answer is no. Collapsing them
        // would let "we don't know" read as "no HDR here", which is a claim, and
        // the wrong one. +menuBadgeForFit: below keeps that distinction, in the
        // wording the menu needs, and sits here rather than beside the menu code
        // so the two cannot come to disagree about what a blank row means.
        case EZHDRFitUnknown:    return @"—";
        // Nothing, rather than an "SDR" badge on every other row: a display with
        // no HDR at any timing would otherwise gain a column of noise saying the
        // same thing about all of it.
        case EZHDRFitNone:       break;
    }
    return nil;
}

+ (nullable NSString *)menuBadgeForFit:(EZHDRFit)fit
{
    switch (fit)
    {
        // "capable", because the menu has no column header to say what the word
        // is doing there, and because the same menu carries an HDR item that
        // really does turn HDR on. A bare "HDR" on a resolution row therefore
        // reads as a second way to switch it on, which is the one thing it is
        // not: it says this mode has the bandwidth for HDR, whether or not HDR
        // is on now. The table keeps the short form — its column header already
        // supplies the noun, and repeating it in every cell is noise.
        case EZHDRFitFull:       return @"HDR capable";
        case EZHDRFitCompressed: return @"HDR capable (DSC)";
        case EZHDRFitReduced:    return @"HDR capable (reduced)";
        // The two silences keep their meanings from +badgeForFit:, but the dash
        // cannot survive the move as a dash: the table's column header is what
        // says which question it is declining to answer, and the menu has no
        // header, so a row reading "3840 × 2160    100 Hz    —" leaves a stray
        // character with nothing to attach it to. Say the noun instead. It still
        // cannot be read as an offer to turn HDR on, because "unknown" is not
        // something a row could do to the display.
        case EZHDRFitUnknown:    return @"HDR unknown";
        case EZHDRFitNone:       break;
    }
    return nil;
}

+ (nullable NSString *)explanationForFit:(EZHDRFit)fit
{
    switch (fit)
    {
        case EZHDRFitFull:
            return @"HDR fits down the cable uncompressed, in 10-bit color with "
                    "no thinning.";
        case EZHDRFitCompressed:
            return @"HDR needs more bandwidth than this resolution and refresh rate "
                    "leave, so macOS compresses the signal (DSC) to fit it. Visually "
                    "near-lossless, but a lower refresh rate avoids it.";
        case EZHDRFitReduced:
            return @"HDR is available here only with the color thinned or at 8 bits "
                    "per channel. A lower resolution or refresh rate gives full "
                    "10-bit color.";
        case EZHDRFitUnknown:
            return @"EZDisplay cannot tell what signal this mode negotiates, so it "
                    "cannot say whether HDR fits. The display advertises no "
                    "timing matching it.";
        case EZHDRFitNone:       break;
    }
    return nil;
}

@end
