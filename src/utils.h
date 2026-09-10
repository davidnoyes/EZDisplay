//
//  utils.h
//
//  Declarations for the private CoreGraphics display-mode services, and the
//  small helpers built on top of them.
//
//  The public CGDisplayMode API cannot see every mode a display advertises, so
//  the mode list this app shows comes from the private CGS calls declared here.
//  They are undocumented, so everything below is a description of an observed
//  binary interface rather than a supported contract, and the static assertions
//  are what stop a wrong description from failing silently.
//

#import <Foundation/Foundation.h>

#include <CoreGraphics/CGDirectDisplay.h>
#include <CoreGraphics/CGDisplayConfiguration.h>
#include <IOKit/IOKitLib.h>
#include <stddef.h>

/// A readable name for a CoreGraphics error, for putting in a message to the
/// user. Unrecognized values come back as `UNKNOWN` rather than nil, so a
/// format string always has something to print.
NSString *DisplayErrorName(CGError error);

/// One entry of the private mode list.
///
/// The layout is fixed by the service that fills it in, so the fields sit at
/// byte offsets that cannot move; the `reserved` members exist only to place
/// the ones that follow them. Two of those offsets are worth stating plainly,
/// because they are easy to get wrong: the refresh rate is a 16-bit value at
/// 0xBE, immediately after another 16-bit field, and the scale factor is a
/// float at 0xD0.
///
/// `DisplayModeDescriptionLength` is the length passed to the service. The
/// structure is deliberately larger than that, so that a service which writes
/// past the length it was handed still lands inside the allocation.
struct DisplayModeDescription
{
    uint32_t number;            // 0x00
    uint32_t flags;             // 0x04
    uint32_t width;             // 0x08
    uint32_t height;            // 0x0C
    uint32_t depth;             // 0x10
    uint32_t reservedA[42];     // 0x14
    uint16_t reservedB;         // 0xBC
    uint16_t refreshRate;       // 0xBE
    uint32_t reservedC[4];      // 0xC0
    float    scale;             // 0xD0
    uint8_t  reservedD[8];      // 0xD4, slack past the requested length
};

static const int DisplayModeDescriptionLength = 0xD4;

static_assert(offsetof(DisplayModeDescription, width)       == 0x08, "width moved");
static_assert(offsetof(DisplayModeDescription, height)      == 0x0C, "height moved");
static_assert(offsetof(DisplayModeDescription, depth)       == 0x10, "depth moved");
static_assert(offsetof(DisplayModeDescription, refreshRate) == 0xBE, "refresh rate moved");
static_assert(offsetof(DisplayModeDescription, scale)       == 0xD0, "scale moved");
static_assert(sizeof(DisplayModeDescription) >= DisplayModeDescriptionLength,
              "the buffer must cover the length handed to the service");

extern "C"
{
void CGSGetCurrentDisplayMode(CGDirectDisplayID display, int *modeNum);
void CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int modeNum);
void CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int *nModes);
void CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx,
                                          DisplayModeDescription *mode, int length);
};

/// Every mode the private service lists for `display`.
///
/// On return `*count` holds the number of modes, and `*modes` a freshly
/// allocated array of that many, which the caller owns and must `free`. Pass a
/// null `modes` to ask only for the count. `*count` is always written, so a
/// display that reports nothing leaves the caller with zero rather than with
/// whatever its variable happened to hold.
void CopyDisplayModeDescriptions(CGDirectDisplayID display,
                                 DisplayModeDescription **modes, int *count);

/// Switches `display` to the private mode numbered `modeNum`, permanently, so
/// the choice outlives a logout. Returns whether it took effect.
bool ApplyDisplayModeNumber(CGDirectDisplayID display, int modeNum);

/// The IOKit service backing `display`, or 0 if none matches. The caller owns
/// the returned port and must `IOObjectRelease` it.
io_service_t CopyDisplayServicePort(CGDirectDisplayID display);
