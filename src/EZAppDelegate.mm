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
#import "CoreBrightness.h"
#import "VolumeKeys.h"
#import "EZDisplay-Swift.h"


/// The most displays this app will look at, matching the interface's limit.
static const uint32_t kMaxDisplays = 0x10;


@interface EZAppDelegate () <NSMenuDelegate>
- (void) displaysReconfigured;
- (void) prefsChanged;
- (void) toggleHDR: (NSMenuItem*) sender;
- (void) setNightShiftState: (NSMenuItem*) sender;
- (NSMenu*) nightShiftMenu;
- (void) toggleTrueTone: (NSMenuItem*) sender;
- (NSMenuItem*) trueToneItem;
- (void) setColorMode: (ColorModeMenuItem*) sender;
- (void) observeBrightnessChanges;
- (void) reloadBrightnessItems;
- (void) startVolumeKeys;
- (void) volumeKeyEvent: (EZMediaKeyPress) press;
- (void) moveVolumeBy: (EZMediaKey) key;
- (void) scheduleMenuRefresh;
- (void) settledMenuRefresh;
- (NSMutableArray<ResMenuItem*>*) thin: (NSArray<ResMenuItem*>*) items
                                toCount: (NSInteger) count
                                aroundW: (int) w h: (int) h scale: (float) s;
- (void) addResolutionGroupTo: (NSMenu*) menu
                        title: (NSString*) title
                         from: (NSArray<ResMenuItem*>*) deduped
                        hidpi: (BOOL) hidpi
                           cw: (int) cw ch: (int) ch cs: (float) cs;
@end


void DisplayReconfigurationCallback(CGDirectDisplayID cg_id,
                                    CGDisplayChangeSummaryFlags change_flags,
                                    void *app_delegate)
{
    EZAppDelegate *appDelegate = (__bridge EZAppDelegate*)app_delegate;
    [appDelegate displaysReconfigured];
}


@implementation EZAppDelegate
{
    NSMenu *statusMenu;
    NSStatusItem *statusItem;
    NSWindowController *editResolutionsController;
    NSWindowController *preferencesController;
    NSWindowController *aboutController;

    // Display ID -> its native width, height and refresh rate. Working these
    // out costs an IOKit round trip, so they are kept rather than re-derived on
    // every menu rebuild.
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *nativeInfoCache;

    // Display ID -> the HDR setting most recently asked for. The hardware goes
    // on reporting the old one until the link finishes settling, so this is
    // what the menu shows in the meantime.
    NSMutableDictionary<NSNumber *, NSNumber *> *pendingHDR;

    // The brightness rows currently in the menu, in the order they were added.
    // Held so a change from elsewhere can move the sliders where they stand,
    // which is the one thing here that must not go through a rebuild.
    NSMutableArray<BrightnessSliderItem *> *brightnessItems;

    // The volume rows, held for the same reason and refreshed differently.
    // Nothing notifies when a monitor's own buttons move its volume, so these
    // re-read when the menu opens rather than on a change.
    NSMutableArray<VolumeSliderItem *> *volumeItems;
}

// An agent app is not the active one when its menu is clicked, and a window put
// up by an inactive app opens behind whatever is in front. The activate call is
// what brings it forward, the same way Settings does it.
- (void) showAbout
{
    if (!aboutController)
        aboutController = [[AboutWindowController alloc] init];
    [aboutController showWindow: self];
    [NSApp activateIgnoringOtherApps: YES];
}


- (void) quit
{
    [NSApp terminate: self];
}


// Hardware changed: native geometry may differ, so drop the cache and rebuild now.
- (void) displaysReconfigured
{
    [nativeInfoCache removeAllObjects];
    [EZColorModes invalidateCaches];
    // A cached AV service belongs to a monitor that was on a port. After a
    // reconfiguration that may be a different monitor, or none, so keeping it
    // would send one display's volume to another.
    [EZDisplayAudio invalidateCaches];
    [self observeBrightnessChanges];
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
        if ([mi isResolutionW: cw height: ch scale: cs])
            [mi setState: NSControlStateValueOn];
        [menu addItem: mi];
    }
}


- (void) refreshStatusMenu
{
    statusMenu = [[NSMenu alloc] initWithTitle: @""];
    statusMenu.delegate = self;
    brightnessItems = [NSMutableArray new];
    volumeItems     = [NSMutableArray new];

    BOOL showStandard      = [EZPrefs resolvedShowStandard];
    BOOL showRefreshMenu   = [EZPrefs resolvedShowRefreshMenu];
    NSInteger curatedCount = [EZPrefs resolvedCuratedCount];

    uint32_t nDisplays;
    CGDirectDisplayID displays[kMaxDisplays];
    CGGetOnlineDisplayList(kMaxDisplays, displays, &nDisplays);

    // Set by the loop below when a built-in panel took the True Tone item, so
    // the whole-machine section does not show a second one.
    BOOL trueToneShown = NO;

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

        // Above the separator, so the display's own dial sits with the lines
        // naming the display rather than among the things it can be switched
        // to. A monitor macOS cannot dim gets no row at all, which is the call
        // the HDR item already makes.
        BrightnessSliderItem* brightness = [BrightnessSliderItem itemForDisplay: display];
        if (brightness)
        {
            [statusMenu addItem: brightness];
            [brightnessItems addObject: brightness];
        }

        // Under brightness, for the same reason brightness sits here: it is the
        // display's own dial. Most monitors have no speakers and get no row.
        VolumeSliderItem* volume = [VolumeSliderItem itemForDisplay: display];
        if (volume)
        {
            [statusMenu addItem: volume];
            [volumeItems addObject: volume];
        }

        [statusMenu addItem: [NSMenuItem separatorItem]];

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
                [mi setTitle: [NSString stringWithFormat: @"%d × %d", [mi width], [mi height]]
                      tagged: @"Native"];
            else
                [mi applyResolutionTitle: YES];
            if ([mi isResolutionW: cw height: ch scale: cs])
                [mi setState: NSControlStateValueOn];
            [statusMenu addItem: mi];
        }

        [statusMenu addItem: [NSMenuItem separatorItem]];

        // --- More Resolutions submenu (full, grouped) ---
        {
            NSMenu* more = [[NSMenu alloc] initWithTitle: @""];
            [self addResolutionGroupTo: more title: @"Retina (HiDPI)" from: deduped hidpi: YES cw: cw ch: ch cs: cs];
            if (showStandard)
                [self addResolutionGroupTo: more title: @"Standard" from: deduped hidpi: NO cw: cw ch: ch cs: cs];

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

        // --- True Tone, next to the panel that has the sensor ---
        // The setting itself is one for the whole machine, so it is shown once:
        // here when there is a built-in panel, and among the whole-machine items
        // at the bottom when there is not. A Mac can have True Tone with no
        // built-in display — a Studio Display has the sensor too — which is why
        // the second placement exists at all.
        if (CGDisplayIsBuiltin(display) && [EZTrueTone available])
        {
            [statusMenu addItem: [self trueToneItem]];
            trueToneShown = YES;
        }

        // --- Color Mode submenu ---
        // Beside HDR rather than only in Preferences, because it is the same
        // kind of decision about the same link, and going through a window to
        // make it was the long way round. The rows are built by EZColorModeUI,
        // so they are the ones Preferences shows, in the same order.
        //
        // Empty until it opens, and deliberately: reading the modes is slow and
        // the answer is worthless if the display was asleep when it was read.
        //
        // Not offered for the internal panel, which has no AV interface to ask
        // and would open on nothing every time. Every other display gets the
        // item, because finding out whether it has modes is the expensive call
        // this is avoiding.
        if (!CGDisplayIsBuiltin(display))
            [statusMenu addItem: [EZColorModeUI menuItemForDisplay: display
                                                            target: self
                                                            action: @selector(setColorMode:)]];

        [statusMenu addItem: [NSMenuItem separatorItem]];
    }

    // --- Settings that belong to the Mac rather than to one display ---
    // Grouped under one separator, which is added only if the group has
    // anything in it: on a single-display Mac with no Night Shift there would
    // otherwise be two separators with nothing between them.
    NSUInteger beforeGlobals = statusMenu.numberOfItems;

    if (nDisplays > 1)
    {
        NSMenuItem* mirroring = [[NSMenuItem alloc] initWithTitle: @"Display mirroring"
                                                           action: @selector(toggleMirroring:)
                                                    keyEquivalent: @""];
        mirroring.state = CGDisplayIsInMirrorSet(CGMainDisplayID());
        [statusMenu addItem: mirroring];
    }

    if ([EZNightShift supported])
    {
        // A submenu rather than three rows here: the top level is a list of
        // separate things, and three rows that are one exclusive choice read as
        // three separate settings sitting next to each other.
        NSMenuItem* nightShift = [[NSMenuItem alloc] initWithTitle: @"Night Shift"
                                                            action: nil
                                                     keyEquivalent: @""];
        nightShift.submenu = [self nightShiftMenu];
        [statusMenu addItem: nightShift];
    }

    // The warmth is not here. It is one value on a slider rather than a choice
    // between a few, which a menu is a poor place for, so it lives in
    // Preferences beside the other settings that take a number.
    if (!trueToneShown && [EZTrueTone available])
        [statusMenu addItem: [self trueToneItem]];

    // Nothing is added to the menu here. The count is: how many displays the
    // volume keys have to talk to, which the tap reads on every press.
    //
    // Zero is how the switch in Settings is honored, and it is the whole
    // mechanism — a tap with no targets passes every key straight through, so
    // turning the feature off needs nothing else. The same zero is what hands
    // the keys back when the last display with speakers is unplugged.
    //
    // This runs on every rebuild, and a preference change causes one, which is
    // what makes the switch take effect without the window being closed.
    [EZVolumeKeys setTargetCount: [EZPrefs resolvedVolumeKeys] ? volumeItems.count : 0];

    if (statusMenu.numberOfItems > beforeGlobals)
        [statusMenu addItem: [NSMenuItem separatorItem]];

    // "Settings…", not "Preferences…": macOS renamed it in Ventura, and
    // MainMenuTests already holds the app menu to that name. This is the menu
    // an agent app is actually used through — the app menu only appears while
    // one of its windows is frontmost — so the stale name was on the item
    // almost everybody sees and the new one on the item almost nobody does.
    [statusMenu addItemWithTitle: @"Settings…"    action: @selector(showPreferences) keyEquivalent: @","];
    [statusMenu addItemWithTitle: @"About EZDisplay" action: @selector(showAbout)    keyEquivalent: @""];
    [statusMenu addItemWithTitle: @"Quit"         action: @selector(quit)            keyEquivalent: @""];
    [statusMenu setDelegate: self];
    [statusItem setMenu: statusMenu];
}


- (void) editResolutions: (EditDisplayPlistItem *)sender {
    editResolutionsController = [[CustomResolutionsWindowController alloc] initWithVendorID: sender.vendorID
                                                                                 productID: sender.productID
                                                                               displayName: sender.displayName
                                                                        displayAspectRatio: 0];
    [editResolutionsController showWindow: self];
    [NSApp activateIgnoringOtherApps: YES];
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
// Built here rather than at both call sites, because the item is the same one
// wherever it is shown: the setting is global, and only its place in the menu
// depends on whether this Mac has a built-in panel.
- (NSMenuItem *) trueToneItem
{
    NSMenuItem* trueTone = [[NSMenuItem alloc] initWithTitle: @"True Tone"
                                                      action: @selector(toggleTrueTone:)
                                               keyEquivalent: @""];
    trueTone.state = [EZTrueTone enabled] ? NSControlStateValueOn : NSControlStateValueOff;
    return trueTone;
}


/// The three states Night Shift can be in, as one exclusive choice.
///
/// The schedule is named on the item rather than left to Preferences to explain,
/// because **Scheduled** on its own does not say what it would do, and the
/// answer is a setting in another window.
- (NSMenu *) nightShiftMenu
{
    NSMenu *menu = [[NSMenu alloc] init];
    // The schedule Scheduled would run, which is the one in force where there
    // is one and the remembered choice where there is not.
    NSString *schedule =
        [EZNightShift descriptionOfScheduleMode: [EZPrefs resolvedNightShiftSchedule]];
    NSArray<NSString *> *titles = @[@"Off",
                                    @"On until tomorrow",
                                    [NSString stringWithFormat: @"Scheduled: %@", schedule]];

    const EZNightShiftState state = [EZNightShift state];
    for (NSInteger i = 0; i < (NSInteger) titles.count; i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: titles[i]
                                                      action: @selector(setNightShiftState:)
                                               keyEquivalent: @""];
        item.tag = i;
        item.state = i == state ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem: item];
    }

    return menu;
}


// The three below answer the two menu problems toggleMirroring: describes. The
// toggles do it the same way: the wanted value comes from what the item showed,
// and a click that asks for the state already in force means the item was
// stale, so the menu is rebuilt and nothing is changed. Night Shift does not
// need the first half — its items name a state outright rather than flipping
// one — and lands on the same second half.
//
// None keeps a record of the value last asked for, which HDR needs and these do
// not: measured against the real daemon, both settings read back their new
// value on the very next call, so there is no settling window for a second
// click to fall into.
//
// A refused write puts up nothing. It can only mean the daemon turned the
// change down, and the rebuild that follows shows the state that really is in
// force — an item whose tick does not move says the same thing an alert would,
// without a modal panel for something the user can simply try again.
- (void) setNightShiftState: (NSMenuItem *)sender
{
    // The tag names the state to move to rather than a change to make, so
    // nothing here has to reason about which way a tick was pointing. That also
    // makes picking the item already ticked a no-op instead of a toggle back.
    EZNightShiftState wanted = (EZNightShiftState) sender.tag;

    if (wanted != [EZNightShift state])
        [EZNightShift setState: wanted scheduleMode: [EZPrefs resolvedNightShiftSchedule]];

    [self refreshStatusMenu];
}


- (void) toggleTrueTone: (NSMenuItem *)sender
{
    BOOL wanted = (sender.state != NSControlStateValueOn);

    if (wanted != [EZTrueTone enabled])
        [EZTrueTone setEnabled: wanted];

    [self refreshStatusMenu];
}


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

    CGError error = [EZDisplays setMirroring: wanted];

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
                         revert: ^{ [EZDisplays setMirroring: !wanted]; }];
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

    // On the shared apply queue rather than straight down the main thread, which
    // is where this used to write. Choosing a color mode now moves HDR as well
    // — the transfer function belongs to it, not to the wire format — and that
    // runs on the queue, so a click here while a color mode is still landing
    // would put two threads into SetHDRModeEnabled on one display with nothing
    // deciding which of them wins.
    //
    // Which means the answer no longer arrives before the menu is rebuilt, so
    // the wanted value is recorded first and taken back below on the one path
    // where the write turns out not to have happened.
    pendingHDR[key] = @(wanted);
    [self scheduleMenuRefresh];

    [SafeApply onApplyQueue: ^{
        BOOL attempted = [EZColorModes setHDREnabled: wanted forDisplay: display];

        if (!attempted)
        {
            // Nothing was attempted, which past the guard above can only mean the
            // display stopped supporting HDR since the menu was built — the item
            // would not be here otherwise. Another stale menu, so answer it the
            // same way: rebuild, which drops the item rather than leaving a dead
            // one with a wrong tick.
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->pendingHDR removeObjectForKey: key];
                [self refreshStatusMenu];
            });
            return;
        }

        // Puts itself on the main thread, so it is called from here rather than
        // hopped to first.
        [SafeApply confirmWithTitle: (wanted ? @"Keep HDR on?" : @"Keep HDR off?")
                             detail: @"The display is switching between HDR and SDR. "
                                      "If the picture looks wrong, wait and it changes back."
                             revert: ^{
            [SafeApply onApplyQueue: ^{
                [EZColorModes setHDREnabled: !wanted forDisplay: display];
            }];
            self->pendingHDR[key] = @(!wanted);
            [self scheduleMenuRefresh];
        }];
    }];
}

// Everything a color-mode change needs is already on the item, and the apply
// itself is EZColorModeUI's — the same call Preferences makes, so the two cannot
// drift on what a confirm-or-revert means here.
//
// No window to hang a problem sheet on, so problems come back as a modal. The
// menu is rebuilt once the link has settled, for the same reason HDR is: the
// filled marker moves to the row that is now running, and a stale menu would go
// on pointing at the old one.
- (void) setColorMode: (ColorModeMenuItem*) sender
{
    [EZColorModeUI apply: sender.mode
               toDisplay: sender.display
                      in: nil
                onSettle: ^{ [self scheduleMenuRefresh]; }];
}

// Registration is per display, so this has to run again whenever the display
// set changes; a monitor plugged in after launch would otherwise report nothing.
- (void) observeBrightnessChanges
{
    __weak EZAppDelegate* weakSelf = self;
    [EZBrightness observeChanges: ^{ [weakSelf reloadBrightnessItems]; }];
}

// A brightness change from anywhere — the function keys, System Settings, or
// another app — moves the rows that are already on screen.
//
// Deliberately not refreshStatusMenu, which is what Night Shift and True Tone
// do here: the brightness keys get pressed with the menu open, and a rebuild
// would close it. Each row re-reads its own display, and one being dragged
// ignores this so the knob stays under the pointer.
- (void) reloadBrightnessItems
{
    for (BrightnessSliderItem* item in brightnessItems)
        [item reload];
}


// Called at launch and again whenever the Accessibility grant changes, because
// granting it is done in System Settings and nothing brings the app back to ask
// a second time. Calling it again with a tap already built switches that tap
// back on rather than building another, so the repetition costs nothing and a
// revoked grant that comes back is picked up without a restart.
- (void) startVolumeKeys
{
    __weak EZAppDelegate* weakSelf = self;
    [EZVolumeKeys startWithHandler: ^(EZMediaKeyPress press) { [weakSelf volumeKeyEvent: press]; }];
}


// A volume key this app took, on the main thread, press, repeat and release
// alike.
//
// Three things happen here and they are on different edges of the key, which is
// why the whole event arrives rather than just the ones that move something.
// The change and the panel go with the press; the click and the spoken
// announcement go with the release, so holding a key ratchets the bar in
// silence and reports once when it comes up. That is what macOS does with the
// keys it keeps, and matching it is the difference between feedback and a burst
// of clicks.
// The click goes first, and the order is the point rather than tidiness. For a
// volume key the two never land on the same event, so it makes no difference
// there — but mute acts and clicks on the same press, and acting on it is a
// blocking DDC write and read-back worth a third of a second. Behind that, the
// one key whose click has to be instant was the only one that arrived late.
// Nothing about the click depends on the write, so there is no reason for it to
// wait for one.
// The announcement is the other way round for exactly the same reason: it says
// what the level *is*, so on mute it has to come after the toggle or it speaks
// the state the key just left.
- (void) volumeKeyEvent: (EZMediaKeyPress) press
{
    if (EZShouldPlayVolumeFeedback(press, VolumeHUD.feedbackSoundEnabled))
        [VolumeHUD playFeedbackSound];

    if (EZMediaKeyShouldAct(press))
        [self moveVolumeBy: press.key];

    if (EZIsVolumeFeedbackMoment(press))
    {
        // The same first-display compromise the panel makes, and read here
        // rather than passed out of the move because a release moves nothing
        // and still has a level to report.
        VolumeSliderItem* shown = volumeItems.firstObject;
        if (shown)
            [VolumeHUD announceWithPercent: (int) shown.shownPercent muted: shown.shownMuted];
    }
}


// Every display with speakers, not one of them. There is one pair of ears and
// the volume keys have always been a control over what reaches them, so a Mac
// with two monitors that both answer moves both — the same thing the system
// keys do to the one output they can see.
//
// The step is worked out from what the row is showing rather than from a read,
// because a read is a bus round trip and a held key would arrive faster than
// the answers. `apply:` writes through the coalescing path, so a held key
// leaves the display at the value the key stopped on rather than walking it
// through every value on the way.
- (void) moveVolumeBy: (EZMediaKey) key
{
    for (VolumeSliderItem* item in volumeItems)
    {
        if (key == EZMediaKeyMute)
        {
            [item toggleMute];
            continue;
        }

        const int now  = (int) item.shownPercent;
        const int next = EZVolumeAfterKey(now, key);
        if (EZVolumeRowNeedsWrite(now, next, item.shownMuted))
            [item apply: next];
    }

    // One panel, showing the first display that answered. Two monitors moved
    // together still have one bar between them, which is the same compromise
    // the system keys make with one output — and if the two are at different
    // volumes it is the wrong one for the second. Left until there are two
    // monitors here to decide it against.
    VolumeSliderItem* shown = volumeItems.firstObject;
    if (!shown)
        return;

    [VolumeHUD showWithLit: EZVolumeChicletsLit((int) shown.shownPercent, shown.shownMuted)
                        of: kEZVolumeChiclets
                     muted: shown.shownMuted];
}


// A DDC read is two frames and 50 ms of settle time per display, so doing this
// in menuWillOpen would hold the menu closed for a tenth of a second on one
// display and longer on two. Dispatched instead, so the menu is on screen
// first and each row corrects itself a moment later — which it can do, because
// a row updates in place rather than through a rebuild.
- (void) menuWillOpen: (NSMenu*) menu
{
    if (menu != statusMenu || volumeItems.count == 0)
        return;

    NSArray<VolumeSliderItem *>* items = [volumeItems copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (VolumeSliderItem* item in items)
            [item reload];
    });
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

    // Before anything can open a window. Without this there is nowhere for a
    // key equivalent to live, so ⌘, and ⌘W and the clipboard shortcuts all do
    // nothing — see MainMenu.swift.
    [EZMainMenu install];

    [EZPrefs registerDefaults];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(prefsChanged)
                                                 name: [EZPrefs changedNotification]
                                               object: nil];

    // Both settings can be changed from System Settings, and neither is a
    // display reconfiguration, so nothing else here would notice. Rebuilt at
    // once rather than through scheduleMenuRefresh: an external change arrives
    // as one event, not the burst a reconfiguration produces.
    __weak EZAppDelegate* weakSelf = self;
    [EZNightShift observeChanges: ^{ [weakSelf refreshStatusMenu]; }];
    [EZTrueTone   observeChanges: ^{ [weakSelf refreshStatusMenu]; }];

    // Brightness takes the other route, for the reason reloadBrightnessItems
    // gives: the rows move, the menu does not.
    [self observeBrightnessChanges];

    // Build the menu before the status item exists, so the first thing shown in
    // the bar already has one rather than briefly clicking through to nothing.
    [self refreshStatusMenu];
    CGDisplayRegisterReconfigurationCallback(DisplayReconfigurationCallback, (__bridge void *) self);

    // After the first build, so the tap already knows whether it has anything
    // to drive before it sees a key.
    [self startVolumeKeys];

    // The Accessibility grant is given and taken away in System Settings, and
    // this notification is the only word of it the app gets. Without it a grant
    // given after launch would need a restart to be used, because a tap cannot
    // be built until it is there.
    //
    // The menu is not rebuilt from here. Nothing in it depends on the grant any
    // more — the item that used to offer it is now a row in the Settings window,
    // which watches this notification itself.
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName: @"com.apple.accessibility.api"
                    object: nil
                     queue: [NSOperationQueue mainQueue]
                usingBlock: ^(NSNotification* note) {
        (void) note;
        // The trust database is written a moment after the notification, so
        // asking now can still get the old answer.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf startVolumeKeys];
        });
    }];

    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSSquareStatusItemLength];
    statusItem.menu = statusMenu;

    // A template image is drawn as a mask, so it follows the menu bar from light
    // to dark instead of staying one fixed color. Set through the accessor:
    // this is Objective-C++, where `template` is a keyword and dot syntax on it
    // does not parse.
    NSImage* icon = [NSImage imageNamed: @"StatusIcon"];
    [icon setTemplate: YES];
    statusItem.button.image = icon;
}

@end
