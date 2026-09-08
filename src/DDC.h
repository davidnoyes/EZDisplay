//
//  DDC.h
//  EZDisplay
//
//  A monitor's own speaker volume and mute, over DDC/CI.
//
//  This is the half of DDC that cannot be tested: finding the display's AV
//  service and handing bytes to IOAVServiceWriteI2C. Every frame it sends is
//  built by `DDCProtocol.h`, which is pure and asserted byte for byte, so the
//  untested part here is the plumbing rather than the protocol.
//
//  Three rules constrain what this is allowed to do, and they are deliberate
//  rather than incidental:
//
//  1. Standard MCCS codes only, and only the two in `DDCProtocol.h`. A
//     vendor-specific code means something different on every panel.
//  2. Nothing is written to a code the display has not first reported, with a
//     range, in a reply to a read. A display that does not advertise volume
//     never receives a volume write.
//  3. Every write is read back, because a successful write is not an applied
//     one — IOAVServiceWriteI2C reports success once the bus takes the bytes,
//     whatever the display then does with them.
//
//  Call these from the main thread. Unlike everything else in this project they
//  are slow: an exchange carries settle delays totalling about 90 ms, and a
//  first call for a display also has to find its service. Cached afterwards,
//  but a caller that drives these from a slider has to coalesce.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A monitor's built-in speakers, as the monitor's own controls rather than
/// macOS's output volume.
///
/// The two are separate dials and this moves neither one on behalf of the
/// other: macOS's output volume decides what leaves the Mac, and this decides
/// what the monitor does with what arrives.
@interface EZDisplayAudio : NSObject

/// Whether this build can reach IOAVService at all. Gate on this before
/// reporting that a display has no speakers, so three missing symbols are not
/// mistaken for a monitor without a volume control.
+ (BOOL) supported;

/// Whether `display` answered a read of the volume code with a usable range.
///
/// The first call for a display is slow and every later one is cached. A false
/// answer covers every way this can fail — no service, no reply, a refusal, or
/// a range of zero — because a caller can do nothing different about any of
/// them.
+ (BOOL) availableForDisplay: (CGDirectDisplayID) display;

/// Volume as a whole percentage, 0 to 100, or -1 when it cannot be read.
///
/// Zero is a real value, so the failure is not one. The display's own range is
/// whatever it published — 64, 100, and 255 all occur — and is converted at
/// this boundary so no caller has to know it.
+ (NSInteger) percentForDisplay: (CGDirectDisplayID) display;

/// Sets it, clamping to 0...100, and returns whether the display took it.
///
/// The return value is a read-back rather than the write call's own result. A
/// display whose dial steps in twos answers 52 to a write of 51 and has plainly
/// taken it, so the dial has to arrive near the value asked for rather than
/// exactly on it. Near, and not merely elsewhere: a write of 20 that sent this
/// monitor's dial to 0 is what a movement test called success.
/// See `EZDDCWriteTookEffect`.
+ (BOOL) setPercent: (NSInteger) percent forDisplay: (CGDirectDisplayID) display;

/// Whether `display` answered a read of the mute code. Cached like
/// `availableForDisplay:`, and independent of it: a monitor can implement one
/// of the two codes and not the other.
///
/// The same test as volume, which asks for a range above zero, and mute is a
/// code of two named values rather than a range. The reference panel publishes
/// a maximum of 2 for it, so the test passes there — but MCCS leaves the
/// maximum field reserved for a non-continuous code, and a display that zeroes
/// it will be told it has no mute when it has one.
///
/// Deliberately not relaxed. Accepting a zero range would mean writing to a
/// code the display never published a range for, which is rule 2 above, and
/// rule 2 is the one standing between this and a vendor-specific write. Losing
/// a mute button on such a panel is a control that degrades; the alternative
/// risks a panel. Revisit only with a display that shows the problem.
+ (BOOL) muteAvailableForDisplay: (CGDirectDisplayID) display;

/// 1 when muted, 0 when not, -1 when it cannot be read.
///
/// Tri-state rather than a BOOL because the code's own off value is 2 and its
/// on value is 1, so there is no honest boolean to return for "no answer".
+ (NSInteger) mutedForDisplay: (CGDirectDisplayID) display;

/// Sets mute, and returns whether the display took it, read back the same way
/// `setPercent:forDisplay:` is — except that the tolerance there works out at
/// zero here. This code's 1 and 2 are names rather than quantities, so near
/// enough is the wrong answer.
+ (BOOL) setMuted: (BOOL) muted forDisplay: (CGDirectDisplayID) display;

/// Drops every cached service and capability.
///
/// Call this on display reconfiguration. A cached service belongs to a monitor
/// that was on a port, and after a reconfiguration it may be a different
/// monitor or none, so keeping it would send volume to the wrong display.
+ (void) invalidateCaches;

@end

NS_ASSUME_NONNULL_END
