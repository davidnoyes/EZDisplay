//
//  DisplayModes.mm
//  EZDisplay
//

#import <AppKit/AppKit.h>
#import <IOKit/graphics/IOGraphicsLib.h>

#import "ColorMode.h"
#import "DisplayModes.h"
#import "utils.h"

#define MAX_DISPLAYS 0x10

@implementation EZDisplayMode
- (instancetype)initWithDisplay:(CGDirectDisplayID)display
                           mode:(const DisplayModeDescription *)mode
                      isCurrent:(BOOL)isCurrent
{
    if ((self = [super init]))
    {
        _displayID   = display;
        _modeNum     = mode->number;
        _width       = mode->width;
        _height      = mode->height;
        _scale       = mode->scale;
        _refreshRate = mode->refreshRate;
        _isHiDPI     = mode->scale >= 2.0f;
        _isCurrent   = isCurrent;
    }
    return self;
}
@end

@interface EZDisplayInfo ()
- (instancetype)initWithDisplay:(CGDirectDisplayID)display name:(NSString *)name
                    nativeWidth:(int)nw nativeHeight:(int)nh nativeRefresh:(int)nr;
@end

@implementation EZDisplayInfo
- (instancetype)initWithDisplay:(CGDirectDisplayID)display name:(NSString *)name
                    nativeWidth:(int)nw nativeHeight:(int)nh nativeRefresh:(int)nr
{
    if ((self = [super init]))
    {
        _displayID = display;
        _name = [name copy];
        _nativeWidth = nw;
        _nativeHeight = nh;
        _nativeRefresh = nr;
    }
    return self;
}
@end


// The native panel mode: the public CoreGraphics mode flagged native by IOKit,
// falling back to the largest-pixel mode. Refresh falls back to the fastest
// mode at the native pixel size when the native mode reports 0 Hz.
static void NativePixels(CGDirectDisplayID display, int *outW, int *outH, int *outHz)
{
    *outW = 0; *outH = 0; *outHz = 0;
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, NULL);
    if (!modes) return;

    CGDisplayModeRef native = NULL, biggest = NULL;
    long bestPixels = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++)
    {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetIOFlags(m) & kDisplayModeNativeFlag)
            native = m;
        long px = (long)CGDisplayModeGetPixelWidth(m) * (long)CGDisplayModeGetPixelHeight(m);
        if (px > bestPixels) { bestPixels = px; biggest = m; }
    }

    CGDisplayModeRef chosen = native ? native : biggest;
    if (chosen)
    {
        *outW = (int)CGDisplayModeGetPixelWidth(chosen);
        *outH = (int)CGDisplayModeGetPixelHeight(chosen);

        // Native refresh = the fastest mode at the native pixel size (the
        // native-flagged mode itself may report a low base rate like 30 Hz).
        for (CFIndex i = 0; i < CFArrayGetCount(modes); i++)
        {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            if ((int)CGDisplayModeGetPixelWidth(m) == *outW &&
                (int)CGDisplayModeGetPixelHeight(m) == *outH)
            {
                int hz = (int)lround(CGDisplayModeGetRefreshRate(m));
                if (hz > *outHz) *outHz = hz;
            }
        }
    }
    CFRelease(modes);
}


static NSString *DisplayName(CGDirectDisplayID display, int index)
{
    // Ask AppKit first: it reports the name macOS itself shows, so the menu and
    // the picker agree with System Settings. The two lookups below are fallbacks
    // because NSScreen only lists displays that are actually active — and a
    // mirrored set is one NSScreen, so the mirrored display is not in here at
    // all. The old IOKit lookup returns nothing on this hardware, which is how
    // turning mirroring on renamed a monitor to "Display 2".
    for (NSScreen *screen in [NSScreen screens])
    {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber.unsignedIntValue != display || screen.localizedName.length == 0)
            continue;

        // Two units of the same model report the same product name, so a pair of
        // identical monitors would give the picker two entries with nothing to
        // choose between them. The positional label this replaced was uglier but
        // never ambiguous; keep that property by numbering the duplicates.
        NSString *name = screen.localizedName;
        int ordinal = 0, total = 0;
        for (NSScreen *other in [NSScreen screens])
        {
            if (![other.localizedName isEqualToString: name])
                continue;
            total++;
            NSNumber *otherNumber = other.deviceDescription[@"NSScreenNumber"];
            if (otherNumber.unsignedIntValue == display)
                ordinal = total;
        }
        return total > 1 ? [NSString stringWithFormat: @"%@ (%d)", name, ordinal] : name;
    }

    // What the display reports over the wire. Reached only when AppKit could not
    // answer, which in practice means a mirrored display, so the cost — a service
    // scan of a few milliseconds — is paid on that path alone. It gives the same
    // string AppKit does, so mirroring no longer renames the monitor.
    //
    // Deliberately not cached, unlike the HDR fit map next door, which is: that
    // one costs 370ms and this costs about seven. A cache here would buy back a
    // few milliseconds per rebuild while a display is mirrored, and would owe the
    // same invalidation care as the expensive one — not a trade worth making.
    NSString *name = [EZColorModes productNameForDisplay: display];
    if (name.length > 0)
        return name;

    io_service_t port = CopyDisplayServicePort(display);
    if (port)
    {
        NSDictionary *info = (__bridge_transfer NSDictionary *)
            IODisplayCreateInfoDictionary(port, kIODisplayOnlyPreferredName);
        NSDictionary *localized = info[@(kDisplayProductName)];
        if (localized.count > 0)
            name = localized[localized.allKeys.firstObject];
    }
    if (name.length == 0)
        name = index == 0 ? @"Main Display" : [NSString stringWithFormat:@"Display %d", index + 1];
    return name;
}


@implementation EZDisplays

+ (NSArray<EZDisplayInfo *> *)onlineDisplays
{
    uint32_t nDisplays = 0;
    CGDirectDisplayID displays[MAX_DISPLAYS];
    CGGetOnlineDisplayList(MAX_DISPLAYS, displays, &nDisplays);

    NSMutableArray<EZDisplayInfo *> *result = [NSMutableArray array];
    for (uint32_t i = 0; i < nDisplays; i++)
    {
        int nw = 0, nh = 0, nr = 0;
        NativePixels(displays[i], &nw, &nh, &nr);
        EZDisplayInfo *d = [[EZDisplayInfo alloc] initWithDisplay:displays[i]
                                                              name:DisplayName(displays[i], (int)i)
                                                       nativeWidth:nw nativeHeight:nh nativeRefresh:nr];
        [result addObject:d];
    }
    return result;
}

+ (NSArray<EZDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)display
{
    int currentModeNum = -1;
    CGSGetCurrentDisplayMode(display, &currentModeNum);

    int nModes = 0;
    DisplayModeDescription *modes = NULL;
    CopyDisplayModeDescriptions(display, &modes, &nModes);
    if (!modes)
        return @[];

    NSMutableArray<EZDisplayMode *> *result = [NSMutableArray arrayWithCapacity:nModes];
    for (int i = 0; i < nModes; i++)
    {
        BOOL isCurrent = (modes[i].number == currentModeNum);
        [result addObject:[[EZDisplayMode alloc] initWithDisplay:display
                                                             mode:&modes[i]
                                                        isCurrent:isCurrent]];
    }
    free(modes);
    return result;
}

+ (BOOL)applyMode:(EZDisplayMode *)mode
{
    return ApplyDisplayModeNumber(mode.displayID, mode.modeNum);
}

+ (BOOL)getNativePixelWidth:(int *)width height:(int *)height refresh:(int *)refresh
                 forDisplay:(CGDirectDisplayID)display
{
    int w = 0, h = 0, hz = 0;
    NativePixels(display, &w, &h, &hz);
    if (width)   *width = w;
    if (height)  *height = h;
    if (refresh) *refresh = hz;
    return w > 0 && h > 0;
}

+ (NSString *)nameForDisplay:(CGDirectDisplayID)display index:(int)index
{
    return DisplayName(display, index);
}

+ (int)currentModeNumForDisplay:(CGDirectDisplayID)display
{
    int modeNum = -1;
    CGSGetCurrentDisplayMode(display, &modeNum);
    return modeNum;
}

+ (BOOL)setModeNum:(int)modeNum forDisplay:(CGDirectDisplayID)display
{
    return ApplyDisplayModeNumber(display, modeNum);
}

@end
