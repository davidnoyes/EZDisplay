//
//  ColorMode.h
//  EZDisplay
//
//  Plain Objective-C bridge over the private IOAVVideoInterface stack, so Swift
//  (the Preferences window) can read a display's colour mode — bit depth, pixel
//  encoding, signal range, transfer function and colorimetry — and the list the
//  display reports as valid at its current timing.
//
//  Reading is most of it; the two writes are the HDR toggle and the colour-mode
//  apply at the bottom. The whole subsystem is private and unversioned, so every
//  entry point degrades to nil/empty/NO when the symbols or the display are not
//  there.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZColorMode : NSObject
@property (readonly) int      elementID;      // IOAV colour element ID
@property (readonly) int      bitDepth;       // 8, 10 …
@property (readonly) uint32_t pixelEncoding;  // RGB 4:4:4, YCbCr 4:2:2 …
@property (readonly) uint32_t dynamicRange;   // signal range: 0 Full, 1 Limited
@property (readonly) uint32_t eotf;           // transfer function: 0 SDR gamma, PQ, HLG …
@property (readonly) uint32_t colorimetry;    // BT.709, BT.2020 …
@property (readonly) BOOL     isCurrent;      // the link's active colour mode
// The display did not advertise this combination itself; the driver derived it.
// Reported rather than hidden, because BetterDisplay offers these as selectable
// connection modes and the 12-bit HDR ones appear only here.
@property (readonly) BOOL     isDerived;
// "10-bit · RGB 4:4:4 · Full · SMPTE ST 2084 (PQ) · BT.2020 (RGB)", built from
// Apple's own enum-to-string helpers.
@property (readonly, copy) NSString *label;
// The same four names on their own, for a caller laying the parts out as
// separate columns or badges rather than one line. "RGB 4:4:4", "Full",
// "SMPTE ST 2084 (PQ)", "BT.2020 (RGB)".
@property (readonly, copy) NSString *pixelEncodingName;
@property (readonly, copy) NSString *dynamicRangeName;
@property (readonly, copy) NSString *eotfName;
@property (readonly, copy) NSString *colorimetryName;
@end

// The colour mode a display link was running before EZDisplay changed it, so the
// change can be undone through the identical call that made it. Opaque on
// purpose: what it holds is a blob of private-API bytes, and the only useful
// thing to do with one is hand it back to +restore:.
@interface EZColorModeRestorePoint : NSObject
@property (readonly) CGDirectDisplayID display;
@end

// What happened to a link change. Three outcomes rather than a BOOL, because
// one of the two failures is not a fault and must not be reported as one:
//
//   Applied     the link is on the mode asked for, whether or not it had to move
//   Superseded  that mode is not valid at the timing now in force, so nothing
//               was attempted — the timing moved and macOS has already picked a
//               colour element to suit it, which it is entitled to do
//   Failed      it should have worked and did not
//
// Collapsing the last two loses the thing a caller most needs to know on the
// revert path: whether the display is still where the user put it, or stuck
// somewhere they did not.
typedef NS_ENUM(NSInteger, EZColorModeChangeResult) {
    EZColorModeChangeApplied,
    EZColorModeChangeSuperseded,
    EZColorModeChangeFailed,
};

@interface EZColorModes : NSObject
// The colour mode the display link is actually running. nil when the private
// API is unavailable or the display cannot be matched to an AV interface.
+ (nullable EZColorMode *)currentForDisplay:(CGDirectDisplayID)display;
// Every mode valid at the display's *current* timing, derived ones included.
// Empty when unavailable. Re-read after a resolution or refresh-rate change.
+ (NSArray<EZColorMode *> *)supportedForDisplay:(CGDirectDisplayID)display;
// The product name the display reports over the wire — "PHL 34M2C8600".
//
// Not a colour mode, and here only because this is the file that knows how to
// match a CGDirectDisplayID to an AV interface. Worth having because it is the
// one name source that does not go through NSScreen: AppKit represents a
// mirrored set as a single screen, so the mirrored display has no NSScreen to
// ask and falls back to a positional label.
//
// nil for a display with no AV interface, for the internal panel, which has an
// interface but no name on it, and for two identical monitors, where the match
// is ambiguous and this fails closed like everything else here.
+ (nullable NSString *)productNameForDisplay:(CGDirectDisplayID)display;

// HDR capability and state, read through CoreDisplay.
+ (BOOL)supportsHDRForDisplay:(CGDirectDisplayID)display;
+ (BOOL)isHDREnabledForDisplay:(CGDirectDisplayID)display;
// Turns HDR on or off. The only write in this file, and the only one the
// colour-mode subsystem needs: the system picks the colour element itself, so
// on the test display turning HDR off moves the link from element 113 (PQ,
// BT.2020) to 107 (SDR gamma, Default RGB), and turning it on moves it back.
//
// NO means nothing was attempted — the symbol is missing, or the display does
// not support HDR. YES means the call was made, not that the link has settled:
// it takes a moment, so re-read `isHDREnabledForDisplay:` and the current mode
// rather than assuming. Reversible by calling this again with the old value,
// which is what makes it safe to route through SafeApply.
+ (BOOL)setHDREnabled:(BOOL)enabled forDisplay:(CGDirectDisplayID)display;

// Switches the display to the colour mode with `elementID`, by restarting the
// display link on it. The display blanks for a moment and comes back on the new
// mode, exactly as it does for a resolution change.
//
// nil means nothing was attempted and nothing changed: the symbols are missing,
// the display cannot be matched, the link would not restart, or the mode is not
// one this display offers at the timing it is running now. nil also covers the
// mode already being the current one, since there is nothing to apply and
// nothing to undo.
//
// A returned restore point is the previous mode, and passing it to +restore:
// uses this same call to go back — which is what makes this safe to route
// through SafeApply's confirm-or-revert. Nothing is written to disk, so an
// applied mode lasts only until the timing changes, the display is
// disconnected, or the machine restarts.
+ (nullable EZColorModeRestorePoint *)applyElementID:(int)elementID
                                            toDisplay:(CGDirectDisplayID)display;

// Puts back the mode a restore point holds. Superseded is the ordinary,
// blameless outcome of the resolution changing while a confirmation was still
// on screen; Failed means the display is still on the mode EZDisplay applied and the
// caller should say so, because otherwise a revert that silently did nothing
// looks exactly like one that worked.
+ (EZColorModeChangeResult)restore:(EZColorModeRestorePoint *)point;
@end


// How HDR fits down the cable at one link timing.
//
// Resolution, refresh rate and colour depth share a single bandwidth budget, so
// HDR is not a property of a display — it is a property of a resolution *at* a
// refresh rate. On the test display 3440 × 1440 carries HDR uncompressed up to
// 144 Hz and needs DSC at 165 and 175. Nothing in the resolution list says so,
// which is what this answers.
//
// "Full" means 10-bit RGB, which carries no chroma subsampling by definition:
// the combination HDR is meant to be seen in, and the first thing a cable runs
// out of room for.
typedef NS_ENUM(NSInteger, EZHDRFit) {
    EZHDRFitUnknown = 0,   // no answer — not the same as an answer of "no"
    EZHDRFitNone,          // the timing carries no HDR colour mode at all
    EZHDRFitReduced,       // HDR, but not as 10-bit RGB in any form
    EZHDRFitCompressed,    // 10-bit RGB HDR, but only with DSC compression
    EZHDRFitFull,          // 10-bit RGB HDR, uncompressed
};

// The HDR fit for every resolution and refresh rate a display can be put into.
//
// Built once and asked many times, because the resolution table runs to well
// over a thousand rows and building it costs an IOKit service scan.
@interface EZHDRFitMap : NSObject
// nil when the private API is unavailable or the display cannot be matched to
// an AV interface — the same conditions under which colour mode reports nothing.
//
// Cached, because the scan is expensive and the answer is durable: see
// +invalidateCaches. Ask for one at the top of each rebuild rather than keeping
// one across rebuilds, so the cache is what decides when it is stale.
//
// The native size is passed in rather than worked out here, so this agrees with
// the "Native" tag the same table shows rather than deriving a second opinion.
// Pass 0 for an unknown native size; rows that need the fallback below then
// report Unknown instead of guessing.
// Named for Swift explicitly: a class method returning instancetype is imported
// as an initializer unless told otherwise, and `EZHDRFitMap(forDisplay:)` reads
// as though it always succeeds when the whole point is that it can return nil.
+ (nullable instancetype)mapForDisplay:(CGDirectDisplayID)display
                           nativeWidth:(int)nativeWidth
                          nativeHeight:(int)nativeHeight
    NS_SWIFT_NAME(map(forDisplay:nativeWidth:nativeHeight:));

// The fit for one desktop mode, which must be given in *pixels* — a HiDPI mode
// is negotiated on the cable at its backing size, not its point size.
- (EZHDRFit)fitForPixelWidth:(int)width height:(int)height refreshRate:(int)refreshRate;

// "HDR", "HDR (DSC)", "HDR (reduced)", or an em dash for Unknown — which says
// there is no answer, as distinct from the nil that says the answer is no. For
// the Preferences table, whose column header supplies the noun.
+ (nullable NSString *)badgeForFit:(EZHDRFit)fit;
// The same answers worded for the status menu, which has no column header and
// does have an HDR item that toggles HDR for real: "HDR capable", so a row
// cannot be read as a second switch, and "HDR unknown" rather than a bare dash,
// which without a header says nothing at all. Beside +badgeForFit: rather than
// in the menu code, so the two wordings cannot come to disagree about which fit
// means what.
+ (nullable NSString *)menuBadgeForFit:(EZHDRFit)fit;
// A sentence for a tooltip, or nil on the same terms.
+ (nullable NSString *)explanationForFit:(EZHDRFit)fit;

// Drops every cached map.
//
// A map describes the timings a display *advertises*, not the one it is running,
// so it outlives any number of resolution and refresh-rate changes — which is
// what makes caching worth doing. What can change it is the display moving: a
// different monitor, or the same one on a different cable, which may advertise
// less. Call this when the set of attached displays changes; nothing here
// observes that.
//
// Every map goes, not the one display that changed, because the key of a map
// that has gone stale is precisely the thing that cannot be trusted — macOS
// recycles display IDs. The cost is one rebuild per display on a hot-plug, which
// is the event where at least one of them needed rebuilding anyway.
//
// The residual, named rather than defended: this depends on the change being
// visible to CoreGraphics. Anything that renegotiates a link without the display
// appearing to go away — a KVM or dock that holds hot-plug-detect asserted while
// it switches source, an MST hub re-arbitrating lanes — leaves the map in place
// and it may then overstate the tier. Unplugging a cable does not have this
// problem; suppressing the unplug is the whole trick of that hardware. Neither
// case has been reproduced, and none of it is distinguishable from here: the
// only stable identity a display offers is vendor plus product, which two
// identical monitors also share.
+ (void)invalidateCaches;
@end

NS_ASSUME_NONNULL_END
