//
//  utils.mm
//
//  Implementations of the helpers declared in utils.h.
//

#import <Foundation/Foundation.h>
#import <IOKit/graphics/IOGraphicsLib.h>

#import "utils.h"


NSString *DisplayErrorName(CGError error)
{
    switch (error)
    {
        case kCGErrorSuccess:           return @"SUCCESS";
        case kCGErrorFailure:           return @"FAILURE";
        case kCGErrorIllegalArgument:   return @"ILLEGAL ARGUMENT";
        case kCGErrorInvalidConnection: return @"INVALID CONNECTION";
        case kCGErrorInvalidContext:    return @"INVALID CONTEXT";
        case kCGErrorCannotComplete:    return @"CANNOT COMPLETE";
        case kCGErrorNotImplemented:    return @"NOT IMPLEMENTED";
        case kCGErrorRangeCheck:        return @"WRONG RANGE";
        case kCGErrorTypeCheck:         return @"TYPE MISMATCH";
        case kCGErrorInvalidOperation:  return @"INVALID OPERATION";
        case kCGErrorNoneAvailable:     return @"NONE AVAILABLE";
        default:                        return @"UNKNOWN";
    }
}


void CopyDisplayModeDescriptions(CGDirectDisplayID display,
                                 DisplayModeDescription **modes, int *count)
{
    int available = 0;
    CGSGetNumberOfDisplayModes(display, &available);
    if (available < 0)
        available = 0;

    *count = available;

    if (modes == NULL)
        return;

    *modes = NULL;
    if (available == 0)
        return;

    DisplayModeDescription *buffer =
        (DisplayModeDescription *) calloc((size_t) available, sizeof(DisplayModeDescription));
    if (buffer == NULL)
    {
        *count = 0;
        return;
    }

    for (int i = 0; i < available; i++)
        CGSGetDisplayModeDescriptionOfLength(display, i, &buffer[i], DisplayModeDescriptionLength);

    *modes = buffer;
}


bool ApplyDisplayModeNumber(CGDirectDisplayID display, int modeNum)
{
    CGDisplayConfigRef config;
    CGError error = CGBeginDisplayConfiguration(&config);
    if (error != kCGErrorSuccess)
    {
        fprintf(stderr, "EZDisplay: could not begin a display configuration (CGError %d)\n", error);
        return false;
    }

    CGSConfigureDisplayMode(config, display, modeNum);

    // Applied permanently, so the mode survives a logout or a restart rather
    // than lasting only for this login session. Completing consumes the
    // configuration either way, so a failure here can be reported but not
    // undone by canceling.
    error = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (error != kCGErrorSuccess)
        fprintf(stderr, "EZDisplay: could not apply the display mode (CGError %d)\n", error);

    return error == kCGErrorSuccess;
}


io_service_t CopyDisplayServicePort(CGDirectDisplayID display)
{
    // MACH_PORT_NULL selects the default IOKit main port. It is the documented
    // equivalent of kIOMasterPortDefault, and unlike that constant it is not
    // deprecated and needs no minimum-version guard.
    io_iterator_t services = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL,
                                     IOServiceMatching("IODisplayConnect"),
                                     &services) != KERN_SUCCESS)
        return 0;

    const CFIndex wantedVendor  = CGDisplayVendorNumber(display);
    const CFIndex wantedProduct = CGDisplayModelNumber(display);

    io_service_t match = 0;
    io_service_t candidate = IO_OBJECT_NULL;

    while (match == 0 && (candidate = IOIteratorNext(services)) != IO_OBJECT_NULL)
    {
        NSDictionary *info = (__bridge_transfer NSDictionary *)
            IODisplayCreateInfoDictionary(candidate, kIODisplayOnlyPreferredName);

        NSNumber *vendor  = info[@(kDisplayVendorID)];
        NSNumber *product = info[@(kDisplayProductID)];

        if (vendor != nil && product != nil &&
            vendor.unsignedLongValue == (unsigned long) wantedVendor &&
            product.unsignedLongValue == (unsigned long) wantedProduct)
            match = candidate;      // kept, so it is not released here
        else
            IOObjectRelease(candidate);
    }

    IOObjectRelease(services);
    return match;
}
