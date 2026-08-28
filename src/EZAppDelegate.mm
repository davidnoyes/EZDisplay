//
//  EZAppDelegate.mm
//
//  The status-bar menu.
//
//  There is no window and no nib: everything the user sees is a menu built in
//  code by `refreshStatusMenu`, from scratch, every time something changes. The
//  menu is therefore a snapshot — an item already on screen goes on showing
//  what it opened with — which is why the actions below re-read the state they
//  are about to change rather than trusting the item they were clicked on.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOKit/graphics/IOGraphicsLib.h>

#import "EZAppDelegate.h"

#import "utils.h"
#import "ResMenuItem.h"
#import "DisplayModes.h"
#import "ColorMode.h"
#import "EZDisplay-Swift.h"


/// The most displays this app will look at, matching the interface's limit.
static const uint32_t kMaxDisplays = 0x10;


@interface EZAppDelegate ()
- (void) displaysReconfigured;
- (void) prefsChanged;
- (void) toggleHDR: (NSMenuItem*) sender;
- (void) scheduleMenuRefresh;
- (void) settledMenuRefresh;
- (NSMutableArray<ResMenuItem*>*) thin: (NSArray<ResMenuItem*>*) items
                                toCount: (NSInteger) count
                                aroundW: (int) w h: (int) h scale: (float) s;
- (void) addResolutionGroupTo: (NSMenu*) menu
                        title: (NSString*) title
                         from: (NSArray<ResMenuItem*>*) deduped
                        hidpi: (BOOL) hidpi
                           cw: (int) cw ch: (int) ch cs: (float) cs
                       hdrFit: (EZHDRFitMap*) hdrFit;
@end


void DisplayReconfigurationCallback(CGDirectDisplayID cg_id,
                                    CGDisplayChangeSummaryFlags change_flags,
                                    void *app_delegate)
{
    EZAppDelegate *appDelegate = (__bridge EZAppDelegate*)app_delegate;
    // The flags matter here and nowhere else in this callback. An HDR fit map
    // costs ~370ms of IOKit to build and stays true across a mode change, so it
    // must survive one — this fires more than once for a single resolution
    // change, and paying that each time is a visible stall. A display arriving,
    // leaving, or being enabled or disabled is the case that can change what a
    // display advertises, including the same monitor coming back on another
    // cable, so those drop the maps.
    if (change_flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag |
                        kCGDisplayEnabledFlag | kCGDisplayDisabledFlag))
        [EZHDRFitMap invalidateCaches];
    [appDelegate displaysReconfigured];
}


@implementation EZAppDelegate
{
    NSMenu *statusMenu;
    NSStatusItem *statusItem;
    NSWindowController *editResolutionsController;
    NSWindowController *preferencesController;

    // Display ID -> its native width, height and refresh rate. Working these
    // out costs an IOKit round trip, so they are kept rather than re-derived on
    // every menu rebuild.
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *nativeInfoCache;

    // Display ID -> the HDR setting most recently asked for. The hardware goes
    // on reporting the old one until the link finishes settling, so this is
    // what the menu shows in the meantime.
    NSMutableDictionary<NSNumber *, NSNumber *> *pendingHDR;
}

// An agent app is not the active one when its menu is clicked, and a panel put
// up by an inactive app opens behind whatever is in front. Activating first is
// what puts it where the user is looking.
- (void) showAbout
{
    [NSApp activateIgnoringOtherApps: YES];
    [NSApp orderFrontStandardAboutPanel: self];
}


- (void) quit
{
    [NSApp terminate: self];
}


// Hardware changed: native geometry may differ, so drop the cache and rebuild now.
- (void) displaysReconfigured
{
    [nativeInfoCache removeAllObjects];
    [self refreshStatusMenu];
}

// A menu-behavior pref changed: coalesce bursts (e.g. dragging the stepper) into
// a single rebuild. Native cache is kept — hardware didn't change.
- (void) prefsChanged
{
    [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(refreshStatusMenu) object: nil];
    [self performSelector: @selector(refreshStatusMenu) withObject: nil afterDelay: 0.15];
}


- (void) showPreferences
{
    if (!preferencesController)
        preferencesController = [[PreferencesWindowController alloc] init];
    [preferencesController showWindow: self];
    [NSApp activateIgnoringOtherApps: YES];
}


// Trim a sorted resolution list to `count` entries centered on the current one.
- (NSMutableArray<ResMenuItem*>*) thin: (NSArray<ResMenuItem*>*) items
                                toCount: (NSInteger) count
                                aroundW: (int) w h: (int) h scale: (float) s
{
    if ((NSInteger)items.count <= count)
        return [items mutableCopy];

    NSInteger cur = -1;
    for (NSInteger k = 0; k < (NSInteger)items.count; k++)
        if ([items[k] isResolutionW: w height: h scale: s]) { cur = k; break; }

    NSInteger start = 0;
    if (cur >= 0)
    {
        start = cur - count / 2;
        if (start < 0) start = 0;
        if (start + count > (NSInteger)items.count) start = (NSInteger)items.count - count;
    }

    NSMutableArray<ResMenuItem*>* out = [NSMutableArray new];
    for (NSInteger k = start; k < start + count; k++)
        [out addObject: items[k]];
    return out;
}


// Append a labeled section (Retina / Standard) of resolution rows to `menu`.
- (void) addResolutionGroupTo: (NSMenu*) menu
                        title: (NSString*) title
                         from: (NSArray<ResMenuItem*>*) deduped
                        hidpi: (BOOL) hidpi
                           cw: (int) cw ch: (int) ch cs: (float) cs
                       hdrFit: (EZHDRFitMap*) hdrFit
{
    NSMutableArray<ResMenuItem*>* group = [NSMutableArray new];
    for (ResMenuItem* item in deduped)
        if ([item isHiDPI] == hidpi)
            [group addObject: item];
    if (group.count == 0)
        return;

    NSMenuItem* head = [[NSMenuItem alloc] initWithTitle: title action: nil keyEquivalent: @""];
    [head setEnabled: NO];
    [menu addItem: head];

    for (ResMenuItem* item in group)
    {
        ResMenuItem* mi = [item copyWithZone: nil];
        [mi applyResolutionTitle: NO];
        // Most of a display's resolutions live only here — the top level is
        // thinned to `curatedCount` — so leaving this untagged would answer the
        // question for six rows and stay silent for the rest.
        [self tagItem: mi withHDRFrom: hdrFit];
        if ([mi isResolutionW: cw height: ch scale: cs])
            [mi setState: NSControlStateValueOn];
        [menu addItem: mi];
    }
}


- (void) refreshStatusMenu
{
    statusMenu = [[NSMenu alloc] initWithTitle: @""];

    BOOL showStandard      = [EZPrefs resolvedShowStandard];
    BOOL showRefreshMenu   = [EZPrefs resolvedShowRefreshMenu];
    NSInteger curatedCount = [EZPrefs resolvedCuratedCount];

    uint32_t nDisplays;
    CGDirectDisplayID displays[kMaxDisplays];
    CGGetOnlineDisplayList(kMaxDisplays, displays, &nDisplays);

    for (int i = 0; i < nDisplays; i++)
    {
        CGDirectDisplayID display = displays[i];

        int mainModeNum;
        CGSGetCurrentDisplayMode(display, &mainModeNum);

        int nModes;
        DisplayModeDescription* modes;
        CopyDisplayModeDescriptions(display, &modes, &nModes);
        if (!modes) continue;  // private API failed for this display; skip it

        NSMutableArray<ResMenuItem*>* allItems = [NSMutableArray new];
        ResMenuItem* currItem = nil;
        for (int j = 0; j < nModes; j++)
        {
            ResMenuItem* item = [[ResMenuItem alloc] initWithDisplay: display andMode: &modes[j]];
            if (!item) continue;
            if (modes[j].number == mainModeNum)
                currItem = item;
            [allItems addObject: item];
        }
        free(modes);

        int   cw = currItem ? [currItem width]  : 0;
        int   ch = currItem ? [currItem height] : 0;
        float cs = currItem ? [currItem scale]  : 0;
        int   currentRefreshRate  = currItem ? [currItem refreshRate]  : 0;
        float currentAspectRatio  = currItem ? [currItem aspectRatio]  : 0;

        // Header: display name, then current and native reference lines.
        NSString* name = [EZDisplays nameForDisplay: display index: i];
        NSMenuItem* header = [[NSMenuItem alloc] initWithTitle: name action: nil keyEquivalent: @""];
        [header setEnabled: NO];
        [statusMenu addItem: header];

        if (currItem)
        {
            NSString* current = currentRefreshRate
                ? [NSString stringWithFormat: @"Current: %d × %d · %d Hz", cw, ch, currentRefreshRate]
                : [NSString stringWithFormat: @"Current: %d × %d", cw, ch];
            NSMenuItem* currentItem = [[NSMenuItem alloc] initWithTitle: current action: nil keyEquivalent: @""];
            [currentItem setEnabled: NO];
            [statusMenu addItem: currentItem];
        }

        // Native is fixed for a display until hardware reconfiguration; cache the
        // numeric pixels so pref-change rebuilds don't re-run CGDisplayCopyAllDisplayModes.
        NSNumber* nativeKey = @(display);
        NSArray<NSNumber*>* nativeInfo = nativeInfoCache[nativeKey];
        if (!nativeInfo)
        {
            int nw = 0, nh = 0, nhz = 0;
            [EZDisplays getNativePixelWidth: &nw height: &nh refresh: &nhz forDisplay: display];
            nativeInfo = @[@(nw), @(nh), @(nhz)];
            nativeInfoCache[nativeKey] = nativeInfo;
        }
        int nativeW  = nativeInfo[0].intValue;
        int nativeH  = nativeInfo[1].intValue;
        int nativeHz = nativeInfo[2].intValue;

        if (nativeW > 0 && nativeH > 0)
        {
            NSString* nativeText = nativeHz > 0
                ? [NSString stringWithFormat: @"Native: %d × %d · %d Hz", nativeW, nativeH, nativeHz]
                : [NSString stringWithFormat: @"Native: %d × %d", nativeW, nativeH];
            NSMenuItem* nativeItem = [[NSMenuItem alloc] initWithTitle: nativeText action: nil keyEquivalent: @""];
            [nativeItem setEnabled: NO];
            [statusMenu addItem: nativeItem];
        }

        [statusMenu addItem: [NSMenuItem separatorItem]];

        // What HDR costs at each resolution and refresh rate. Built once per
        // display here rather than per item: it scans IOKit, and the two loops
        // below both ask it. nil on a display with no AV interface, which the
        // helper below turns into no tag at all.
        EZHDRFitMap* hdrFit = [EZHDRFitMap mapForDisplay: display
                                               nativeWidth: nativeW
                                              nativeHeight: nativeH];

        // Dedup by geometry (width, height, scale). Representative mode prefers
        // the current refresh rate, otherwise the highest available.
        NSMutableDictionary<NSString*, ResMenuItem*>* byGeom = [NSMutableDictionary new];
        for (ResMenuItem* item in allItems)
        {
            NSString* key = [NSString stringWithFormat: @"%dx%d@%.2f", [item width], [item height], [item scale]];
            ResMenuItem* ex = byGeom[key];
            if (!ex) { byGeom[key] = item; continue; }
            BOOL itemCur = ([item refreshRate] == currentRefreshRate);
            BOOL exCur   = ([ex refreshRate]   == currentRefreshRate);
            if (itemCur && !exCur)
                byGeom[key] = item;
            else if (itemCur == exCur && [item refreshRate] > [ex refreshRate])
                byGeom[key] = item;
        }
        NSArray<ResMenuItem*>* deduped = [byGeom.allValues sortedArrayUsingSelector: @selector(compareResMenuItem:)];

        // --- Curated list: HiDPI resolutions in the display's aspect ratio ---
        NSMutableArray<ResMenuItem*>* curated = [NSMutableArray new];
        for (ResMenuItem* item in deduped)
            if ([item isHiDPI] && [item height] > 0
                && [item aspectRatio] == currentAspectRatio)
                [curated addObject: item];

        // Fall back to the full list when there are no HiDPI native-ratio modes
        // (e.g. a non-Retina display, or an unusual current aspect ratio) or when
        // the current mode isn't among them, so the top level always offers real
        // choices and shows the current resolution.
        BOOL currentInCurated = NO;
        for (ResMenuItem* item in curated)
            if ([item isResolutionW: cw height: ch scale: cs]) { currentInCurated = YES; break; }
        if (curated.count == 0 || (currItem && !currentInCurated))
            curated = [deduped mutableCopy];

        curated = [self thin: curated toCount: curatedCount aroundW: cw h: ch scale: cs];

        // Always offer the display's native resolution as a quick choice, even
        // though it's a 1× (non-HiDPI) mode outside the HiDPI curated set.
        if (nativeW > 0)
        {
            BOOL haveNative = NO;
            for (ResMenuItem* item in curated)
                if ([item width] == nativeW && [item height] == nativeH && ![item isHiDPI]) { haveNative = YES; break; }
            if (!haveNative)
                for (ResMenuItem* item in deduped)
                    if ([item width] == nativeW && [item height] == nativeH && ![item isHiDPI])
                    {
                        [curated addObject: item];
                        [curated sortUsingSelector: @selector(compareResMenuItem:)];
                        break;
                    }
        }

        for (ResMenuItem* item in curated)
        {
            ResMenuItem* mi = [item copyWithZone: nil];
            BOOL isNative = (nativeW > 0 && [mi width] == nativeW && [mi height] == nativeH && ![mi isHiDPI]);
            if (isNative)
                [mi setTitle: [NSString stringWithFormat: @"%d × %d    Native", [mi width], [mi height]]];
            else
                [mi applyResolutionTitle: YES];
            // The rate this row would apply is the representative one the dedup
            // above picked, so the tag describes what clicking actually does
            // rather than the resolution in the abstract. The Refresh Rate
            // submenu is where the rest of the rates get their own answer.
            [self tagItem: mi withHDRFrom: hdrFit];
            if ([mi isResolutionW: cw height: ch scale: cs])
                [mi setState: NSControlStateValueOn];
            [statusMenu addItem: mi];
        }

        [statusMenu addItem: [NSMenuItem separatorItem]];

        // --- More Resolutions submenu (full, grouped) ---
        {
            NSMenu* more = [[NSMenu alloc] initWithTitle: @""];
            [self addResolutionGroupTo: more title: @"Retina (HiDPI)" from: deduped hidpi: YES cw: cw ch: ch cs: cs hdrFit: hdrFit];
            if (showStandard)
                [self addResolutionGroupTo: more title: @"Standard" from: deduped hidpi: NO cw: cw ch: ch cs: cs hdrFit: hdrFit];

            [more addItem: [NSMenuItem separatorItem]];
            [more addItem: [[EditDisplayPlistItem alloc] initWithTitle: @"Edit Custom…"
                                                                action: @selector(editResolutions:)
                                                              vendorID: CGDisplayVendorNumber(display)
                                                             productID: CGDisplayModelNumber(display)
                                                           displayName: name]];

            NSMenuItem* moreItem = [[NSMenuItem alloc] initWithTitle: @"More Resolutions" action: nil keyEquivalent: @""];
            [moreItem setSubmenu: more];
            [statusMenu addItem: moreItem];
        }

        // --- Refresh Rate submenu (rates for the current resolution) ---
        if (showRefreshMenu)
        {
            NSMutableSet<NSNumber*>* seenRates = [NSMutableSet new];
            NSMutableArray<ResMenuItem*>* rateItems = [NSMutableArray new];
            for (ResMenuItem* item in allItems)
                if ([item width] == cw && [item height] == ch && [item scale] == cs && [item refreshRate] > 0)
                {
                    NSNumber* f = @([item refreshRate]);
                    if ([seenRates containsObject: f]) continue;
                    [seenRates addObject: f];
                    [rateItems addObject: item];
                }
            [rateItems sortUsingSelector: @selector(compareResMenuItem:)];

            if (rateItems.count > 1)
            {
                NSMenu* rates = [[NSMenu alloc] initWithTitle: @""];
                for (ResMenuItem* item in rateItems)
                {
                    ResMenuItem* mi = [item copyWithZone: nil];
                    [mi applyRefreshRateTitle];
                    // The point of the whole feature: these rows differ only by
                    // refresh rate, and that is exactly what decides whether HDR
                    // fits down the cable uncompressed.
                    [self tagItem: mi withHDRFrom: hdrFit];
                    if ([mi refreshRate] == currentRefreshRate)
                        [mi setState: NSControlStateValueOn];
                    [rates addItem: mi];
                }
                NSMenuItem* ratesItem = [[NSMenuItem alloc] initWithTitle: @"Refresh Rate" action: nil keyEquivalent: @""];
                [ratesItem setSubmenu: rates];
                [statusMenu addItem: ratesItem];
            }
        }

        // --- HDR, when this display can do it ---
        // Offered here as well as in Preferences so it sits beside the resolution
        // and refresh rate it shares a bandwidth budget with. Displays that
        // cannot do HDR get no item at all rather than a disabled one: a menu is
        // a list of things you can do, where Preferences can afford to explain
        // why something is unavailable.
        if ([EZColorModes supportsHDRForDisplay: display])
        {
            NSMenuItem* hdr = [[NSMenuItem alloc] initWithTitle: @"HDR"
                                                         action: @selector(toggleHDR:)
                                                  keyEquivalent: @""];
            // Show the value last asked for while the link is settling, so the
            // tick matches what the user just did rather than lagging it — and
            // so it agrees with the guard in toggleHDR:, which reads the same
            // pair. Without this a click during the settle window looks ignored.
            NSNumber* pending = pendingHDR[@(display)];
            hdr.state = (pending ? pending.boolValue : [EZColorModes isHDREnabledForDisplay: display])
                      ? NSControlStateValueOn : NSControlStateValueOff;
            hdr.representedObject = @(display);
            [statusMenu addItem: hdr];
        }

        [statusMenu addItem: [NSMenuItem separatorItem]];
    }

    if (nDisplays > 1)
    {
        NSMenuItem* mirroring = [[NSMenuItem alloc] initWithTitle: @"Display mirroring"
                                                           action: @selector(toggleMirroring:)
                                                    keyEquivalent: @""];
        mirroring.state = CGDisplayIsInMirrorSet(CGMainDisplayID());
        [statusMenu addItem: mirroring];
        [statusMenu addItem: [NSMenuItem separatorItem]];
    }

    [statusMenu addItemWithTitle: @"Preferences…" action: @selector(showPreferences) keyEquivalent: @","];
    [statusMenu addItemWithTitle: @"About EZDisplay" action: @selector(showAbout)    keyEquivalent: @""];
    [statusMenu addItemWithTitle: @"Quit"         action: @selector(quit)            keyEquivalent: @""];
    [statusMenu setDelegate: self];
    [statusItem setMenu: statusMenu];
}



// Appends the HDR tag to a menu item whose title is already set, so a
// resolution or a refresh rate says what picking it would cost on the cable.
//
// Silent when the answer is no — no AV interface, or no HDR at that timing. A
// display that cannot do HDR anywhere therefore gets no tags at all rather than
// "SDR" repeated down the menu, matching how the HDR item itself is simply
// absent for such a display. A mode whose timing could not be resolved is not
// silent, though: it gets the same em dash the Preferences table shows, because
// "we could not tell" must not read as "no".
- (void) tagItem: (ResMenuItem*) item withHDRFrom: (EZHDRFitMap*) map
{
    if (!map) return;

    // Pixels, not points: a HiDPI mode is negotiated on the cable at its
    // backing size, so 2752 × 1152 Retina is a 5504 × 2304 signal.
    int pxW = (int) lroundf([item width]  * [item scale]);
    int pxH = (int) lroundf([item height] * [item scale]);
    EZHDRFit fit = [map fitForPixelWidth: pxW height: pxH refreshRate: [item refreshRate]];

    NSString* badge = [EZHDRFitMap menuBadgeForFit: fit];
    if (!badge) return;
    [item setTitle: [NSString stringWithFormat: @"%@    %@", [item title], badge]];
    [item setToolTip: [EZHDRFitMap explanationForFit: fit]];
}



- (void) editResolutions: (EditDisplayPlistItem *)sender {
    editResolutionsController = [[CustomResolutionsWindowController alloc] initWithVendorID: sender.vendorID
                                                                                 productID: sender.productID
                                                                               displayName: sender.displayName
                                                                        displayAspectRatio: 0];
    [editResolutionsController showWindow: self];
    [NSApp activateIgnoringOtherApps: YES];
}



// Turn mirroring on (mirror all displays to the main one) or off. Reused by the
// toggle and its revert closure.
static CGError applyMirroring(BOOL on)
{
    CGDisplayCount count;
    CGDirectDisplayID displays[kMaxDisplays];
    CGGetOnlineDisplayList(kMaxDisplays, displays, &count);

    // CoreGraphics states mirroring one display at a time, as "this display
    // follows that one". kCGNullDirectDisplay is how it spells "follows
    // nothing", so the same loop both builds the mirror set and dismantles it.
    CGDirectDisplayID target = on ? CGMainDisplayID() : kCGNullDirectDisplay;

    CGDisplayConfigRef configRef;
    CGError error = CGBeginDisplayConfiguration(&configRef);
    if (error != kCGErrorSuccess) return error;

    for (CGDisplayCount i = 0; i < count; i++) {
        // Nothing can be asked to follow itself. When unmirroring the target
        // is the null display, which no real display ever matches, so every
        // one of them is released.
        if (displays[i] == target) continue;

        error = CGConfigureDisplayMirrorOfDisplay(configRef, displays[i], target);
        if (error != kCGErrorSuccess) {
            CGCancelDisplayConfiguration(configRef);
            return error;
        }
    }

    return CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
}


// The same two menu problems toggleHDR: describes below, and the same answers.
// A menu item does not toggle its own state when clicked, so the wanted value is
// the inverse of what is shown; and what is shown can be out of date by the time
// it is clicked. Flipping the *live* state instead, as this used to, hid the
// staleness by inverting the request: a stale unticked item meant the user asked
// for mirroring on and got it turned off.
//
// Stale how, when a mirroring change is a display reconfiguration and that
// rebuilds this menu? Because rebuilding replaces the menu object, and a menu
// already on screen goes on showing the items it opened with. So the reachable
// case is the menu left open while something else — System Settings, another
// tool — changes mirroring underneath it.
//
// No record of what was last asked for, unlike HDR, which needs one because the
// display reports the old value for a second or two after a toggle. Mirroring
// has no such lag to cover: the rebuild above lands before the menu can be
// opened again, so the next click is on a fresh item.
- (void) toggleMirroring: (NSMenuItem *)sender {
    BOOL wanted = (sender.state != NSControlStateValueOn);

    // Asking for the state the displays are already in is not a change. It means
    // the menu was stale, so correct it rather than starting a countdown to
    // revert something that never happened.
    if (wanted == CGDisplayIsInMirrorSet(CGMainDisplayID()))
    {
        [self refreshStatusMenu];
        return;
    }

    CGError error = applyMirroring(wanted);

    if (error != kCGErrorSuccess)
    {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.window.level = NSFloatingWindowLevel;
        alert.alertStyle   = NSAlertStyleCritical;
        alert.messageText  = [NSString stringWithFormat:@"Cannot mirror displays!\nError: %@ (%d)", DisplayErrorName(error), error];

        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
        return;
    }

    [SafeApply confirmWithTitle: @"Keep display mirroring change?"
                         detail: (wanted ? @"Mirroring on" : @"Mirroring off")
                         revert: ^{ applyMirroring(!wanted); }];
}


// The Preferences checkbox's twin: same capability gate, same confirm-or-revert,
// same wording. Two differences come from being a menu rather than a checkbox.
// A menu item does not toggle its own state when clicked, so the wanted value is
// the opposite of what is shown. And the menu is built on demand rather than
// bound to anything, so what it shows can be out of date by the time it is
// clicked — hence the re-read below and the rebuild afterwards.
- (void) toggleHDR: (NSMenuItem*) sender
{
    CGDirectDisplayID display = (CGDirectDisplayID)[sender.representedObject unsignedIntValue];
    NSNumber* key = @(display);
    BOOL wanted = (sender.state != NSControlStateValueOn);

    // Compare against the value last asked for, falling back to the hardware
    // when nothing is in flight. Reading the hardware alone is not enough: it
    // reports the old value for a second or two after a toggle, so a second
    // click inside that window would slip past this guard and queue a duplicate
    // revert — one change, two identical bullets on the confirm panel and two
    // staggered reverts of the same thing.
    NSNumber* inFlight = pendingHDR[key];
    BOOL current = inFlight ? inFlight.boolValue : [EZColorModes isHDREnabledForDisplay: display];

    // Asking for the state the display is already in is not a change. It means
    // the menu was stale, so correct it rather than starting a countdown to
    // revert something that never happened.
    if (wanted == current)
    {
        [self refreshStatusMenu];
        return;
    }

    // Nothing was attempted, which past the guard above can only mean the display
    // stopped supporting HDR since the menu was built — the item would not be
    // here otherwise. Another stale menu, so answer it the same way: rebuild,
    // which drops the item rather than leaving a dead one with a wrong tick.
    if (![EZColorModes setHDREnabled: wanted forDisplay: display])
    {
        [self refreshStatusMenu];
        return;
    }

    pendingHDR[key] = @(wanted);
    [self scheduleMenuRefresh];

    [SafeApply confirmWithTitle: (wanted ? @"Keep HDR on?" : @"Keep HDR off?")
                         detail: @"The display is switching between HDR and SDR. "
                                  "If the picture looks wrong, wait and it changes back."
                         revert: ^{
        [EZColorModes setHDREnabled: !wanted forDisplay: display];
        self->pendingHDR[key] = @(!wanted);
        [self scheduleMenuRefresh];
    }];
}

// The link takes a second or two to settle, so an immediate rebuild would read
// the old state back.
//
// Scheduled under its own selector rather than refreshStatusMenu's, because
// cancelPreviousPerformRequests matches on the selector: sharing one with
// prefsChanged's 0.15s rebuild would let any unrelated preference change cancel
// this and rebuild too early, leaving a checkmark that is wrong and that nothing
// later corrects. Still coalesced against itself, because a revert chain can ask
// for several.
- (void) scheduleMenuRefresh
{
    [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(settledMenuRefresh) object: nil];
    [self performSelector: @selector(settledMenuRefresh) withObject: nil afterDelay: 1.5];
}

// The link has settled, so the hardware is authoritative again.
- (void) settledMenuRefresh
{
    [pendingHDR removeAllObjects];
    [self refreshStatusMenu];
}


// Every resolution and refresh-rate row lands here. The mode change itself goes
// through SafeApply, so a picture that comes back unreadable reverts on its own.
- (void) setMode: (ResMenuItem*) item
{
    NSString* detail = item.refreshRate
        ? [NSString stringWithFormat: @"%d × %d · %d Hz", item.width, item.height, item.refreshRate]
        : [NSString stringWithFormat: @"%d × %d", item.width, item.height];

    [SafeApply setDisplayMode: item.display modeNum: item.modeNum detail: detail];
}


- (void) applicationDidFinishLaunching: (NSNotification*) notification
{
    nativeInfoCache = [NSMutableDictionary new];
    pendingHDR = [NSMutableDictionary new];

    [EZPrefs registerDefaults];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(prefsChanged)
                                                 name: [EZPrefs changedNotification]
                                               object: nil];

    // Build the menu before the status item exists, so the first thing shown in
    // the bar already has one rather than briefly clicking through to nothing.
    [self refreshStatusMenu];
    CGDisplayRegisterReconfigurationCallback(DisplayReconfigurationCallback, (__bridge void *) self);

    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSSquareStatusItemLength];
    statusItem.menu = statusMenu;

    // A template image is drawn as a mask, so it follows the menu bar from light
    // to dark instead of staying one fixed colour. Set through the accessor:
    // this is Objective-C++, where `template` is a keyword and dot syntax on it
    // does not parse.
    NSImage* icon = [NSImage imageNamed: @"StatusIcon"];
    [icon setTemplate: YES];
    statusItem.button.image = icon;
}

@end
