//
//  ColorMode.h
//  EZDisplay
//
//  Plain Objective-C bridge over the private IOAVVideoInterface stack, so Swift
//  (the Preferences window) can read a display's color mode — bit depth, pixel
//  encoding, signal range, transfer function and colorimetry — and the list the
//  display reports as valid at its current timing.
//
//  Reading is most of it; the two writes are the HDR toggle and the color-mode
//  apply at the bottom. The whole subsystem is private and unversioned, so every
//  entry point degrades to nil/empty/NO when the symbols or the display are not
//  there.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZColorMode : NSObject
@property (readonly) int      elementID;      // IOAV color element ID
@property (readonly) int      bitDepth;       // 8, 10 …
@property (readonly) uint32_t pixelEncoding;  // RGB 4:4:4, YCbCr 4:2:2 …
@property (readonly) uint32_t dynamicRange;   // signal range: 0 Full, 1 Limited
@property (readonly) uint32_t eotf;           // transfer function: 0 SDR gamma, PQ, HLG …
@property (readonly) uint32_t colorimetry;    // BT.709, BT.2020 …
@property (readonly) BOOL     isCurrent;      // the link's active color mode
// A PQ or HLG transfer function. Says only that this is one of the HDR modes,
// not that HDR will look right in it.
@property (readonly) BOOL     isHDR;
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

// The state a display was in before EZDisplay changed its color mode, so the
// change can be undone through the identical call that made it: the link's
// color bytes, and macOS's HDR mode, since applying a color mode moves that
// too and half an undo is worse than none. Opaque on purpose — what it holds is
// private-API bytes, and the only useful thing to do with one is hand it back to
// +restore:.
@interface EZColorModeRestorePoint : NSObject
@property (readonly) CGDirectDisplayID display;
@end

// What happened to a link change. Three outcomes rather than a BOOL, because
// one of the two failures is not a fault and must not be reported as one:
//
//   Applied     the link is on the mode asked for, whether or not it had to move
//   Superseded  that mode is not valid at the timing now in force, so nothing
//               was attempted — the timing moved and macOS has already picked a
//               color element to suit it, which it is entitled to do
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
// The color mode the display link is actually running. nil when the private
// API is unavailable or the display cannot be matched to an AV interface.
+ (nullable EZColorMode *)currentForDisplay:(CGDirectDisplayID)display;
// Every mode valid at the display's *current* timing, derived ones included.
// Empty when unavailable. Re-read after a resolution or refresh-rate change.
//
// HDR modes are dropped when the system reports the display cannot do HDR where
// it is now. The display's own element list is no guide to this: the test
// Philips advertises the same PQ modes at all sixty of its link timings, down
// to 640 × 480, so trusting it would offer an HDR mode at every resolution and
// let the user apply one the system has already ruled out. CoreDisplay's
// verdict is the only per-timing answer there is, and macOS owns the question.
+ (NSArray<EZColorMode *> *)supportedForDisplay:(CGDirectDisplayID)display;
// The product name the display reports over the wire — "PHL 34M2C8600".
//
// Not a color mode, and here only because this is the file that knows how to
// match a CGDirectDisplayID to an AV interface. Worth having because it is the
// one name source that does not go through NSScreen: AppKit represents a
// mirrored set as a single screen, so the mirrored display has no NSScreen to
// ask and falls back to a positional label.
//
// nil for a display with no AV interface, for the internal panel, which has an
// interface but no name on it, and for two identical monitors, where the match
// is ambiguous and this fails closed like everything else here.
+ (nullable NSString *)productNameForDisplay:(CGDirectDisplayID)display;

// Drops the cached per-display timing lists. Call on reconfiguration, which is
// when a display ID can come to mean a different monitor.
//
// The lists are cached because reading one costs 358 ms — measured — against
// 7 ms for the rest of a color-mode read, and the Color Mode submenu would pay
// it on every open. What a display advertises does not change under it; which
// timing is in force does, and that is read fresh every time.
+ (void)invalidateCaches;

// Whether more than one AV interface reporting the same product means more than
// one monitor.
//
// It usually does not. The DCP exposes a proxy per stream, so a single display
// can present several interfaces carrying byte-identical product attributes.
// Treating that as two monitors reports nothing for a perfectly ordinary
// display, taking the product name and color mode down together. The count of
// *displays* CoreGraphics reports for the product is what settles it.
//
// Deliberately not private: this is the judgment the color-mode and HDR
// features hang off, and the private-API path around it cannot be exercised by
// a test.
+ (BOOL)matchIsAmbiguousWithInterfaces:(NSUInteger)matchingInterfaces
                       sharingDisplays:(NSUInteger)displaysWithSameProduct;

// Which of the matched AV interfaces to read from, given one liveness flag per
// interface in the order the IOKit iterator yielded them.
//
// Recognizing that several proxies are one monitor is only half of it, because
// they are not interchangeable. Both of the test display's carry the same
// product attributes and the same color and timing elements, but only one is
// attached to the live link; the other answers GetLinkData with
// kIOReturnNoDevice. Taking the first is a coin toss, and on that display it
// lands on the dead one — which reads as the display having no color mode at
// all, while everything built from the element dictionaries carries on working
// and hides the fault.
//
// The first live interface, or the first match when none is live: a sleeping
// display has no link and still has a product name and a timing list worth
// reading. NSNotFound when nothing matched.
+ (NSUInteger)preferredMatchIndexWithLiveness:(NSArray<NSNumber *> *)liveness;

// The same choice, but told which of the matched interfaces sit on the port the
// display is actually attached to. One flag per interface in each array, in the
// order the IOKit iterator yielded them.
//
// Product attributes identify a model, not a monitor, so two of the same
// display cannot be told apart by them — which is why the ambiguous case used
// to report no color mode for either of them. The registry knows better: each
// display hangs off a numbered port, the AV proxies for that port carry the
// same node in their own path, and two identical monitors are necessarily on
// two different ports.
//
// So the port wins outright wherever it is known, over both the product match
// and liveness — a live interface on another port is another monitor's, and
// choosing it would report its color mode as this display's. Liveness only
// orders the candidates within the right port.
//
// Where no interface carries the port — CoreDisplay would not say, or the
// registry is not shaped the way this expects — the old rule applies unchanged,
// fail-closed ambiguity check and all, so a display that worked before still
// works.
+ (NSUInteger)preferredMatchIndexOnPort:(NSArray<NSNumber *> *)onPort
                               liveness:(NSArray<NSNumber *> *)liveness
                        sharingDisplays:(NSUInteger)displaysWithSameProduct;

// Whether a mode the display advertises for the current timing belongs in the
// list offered for it.
//
// The display's element list is no guide to HDR on its own: the test Philips
// advertises the same PQ elements at all sixty of its timings, 640 × 480
// included. Offering them all is how a list comes to invite the user to apply
// an HDR mode the system has already ruled out — the inaccurate assessment this
// replaced. Only CoreDisplay knows whether HDR is reachable where the display
// is now, so an HDR mode is offered only when it says so.
//
// The mode the link is running is kept whatever the verdict. A list that omits
// the current row contradicts itself, and hiding that row would hide the way
// back off it.
//
// Deliberately not private, for the same reason as the two above: this is a
// judgment worth testing, and the private-API path around it is not.
+ (BOOL)shouldOfferMode:(BOOL)modeIsHDR
           hdrAvailable:(BOOL)hdrAvailable
              isCurrent:(BOOL)isCurrent;

// Whether applying a color mode has to move macOS's HDR mode first.
//
// It does whenever the two disagree. A color mode carries a transfer function,
// and the transfer function is not the wire format's to choose: it belongs to
// the HDR mode, which is what the compositor renders. Applying a PQ mode with
// HDR off leaves the cable declaring PQ while the compositor emits plain gamma,
// and the display decodes one as the other — the wrong colors this coupling
// exists to prevent.
//
// Not when HDR is unavailable, and that is the case worth stating separately:
// there is nothing to move, so the wire format goes on alone, and nothing must
// later try to put back an HDR mode that was never taken away.
//
// Deliberately not private, for the same reason as the ones above.
+ (BOOL)shouldChangeHDRTo:(BOOL)wanted
                     from:(BOOL)current
             hdrAvailable:(BOOL)hdrAvailable;

// HDR capability and state, read through CoreDisplay.
+ (BOOL)supportsHDRForDisplay:(CGDirectDisplayID)display;
+ (BOOL)isHDREnabledForDisplay:(CGDirectDisplayID)display;
// Turns HDR on or off. The only write in this file, and the only one the
// color-mode subsystem needs: the system picks the color element itself, so
// on the test display turning HDR off moves the link from element 113 (PQ,
// BT.2020) to 107 (SDR gamma, Default RGB), and turning it on moves it back.
//
// NO means nothing was attempted — the symbol is missing, or the display does
// not support HDR. YES means the call was made, not that the link has settled:
// it takes a moment, so re-read `isHDREnabledForDisplay:` and the current mode
// rather than assuming. Reversible by calling this again with the old value,
// which is what makes it safe to route through SafeApply.
+ (BOOL)setHDREnabled:(BOOL)enabled forDisplay:(CGDirectDisplayID)display;

// Switches the display to the color mode with `elementID`, by restarting the
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


NS_ASSUME_NONNULL_END
