//
//  DisplayPort.mm
//  EZDisplay
//

#import <dlfcn.h>

#import "DisplayPort.h"

// Everything CoreDisplay knows about a display ID, including IODisplayLocation
// — the registry path of the framebuffer it is attached to. Private and
// unversioned, so it is looked up by name and its absence is a nil answer
// rather than a crash.
typedef CFDictionaryRef (*FnDisplayInfo)(CGDirectDisplayID);

static FnDisplayInfo DisplayInfoFunction(void)
{
    static FnDisplayInfo fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        fn = (FnDisplayInfo) dlsym(RTLD_DEFAULT, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    return fn;
}

NSString *EZPortNodeForDisplay(CGDirectDisplayID display)
{
    FnDisplayInfo displayInfo = DisplayInfoFunction();
    if (!displayInfo)
        return nil;

    NSDictionary *info = (__bridge_transfer NSDictionary *) displayInfo(display);
    NSString *location = info[@"IODisplayLocation"];
    if (![location isKindOfClass:[NSString class]])
        return nil;

    // ".../AppleH15IO/dispext0@4000000/IOMobileFramebufferShim" — the component
    // that starts "disp" and carries a unit address is the one.
    for (NSString *component in [location componentsSeparatedByString:@"/"])
    {
        NSRange at = [component rangeOfString:@"@"];
        if (at.location != NSNotFound && [component hasPrefix:@"disp"])
            return [component substringToIndex:at.location];
    }
    return nil;
}

BOOL EZServiceIsOnPort(io_service_t service, NSString *portNode)
{
    io_string_t path = {0};
    if (IORegistryEntryGetPath(service, kIOServicePlane, path) != KERN_SUCCESS)
        return NO;
    return [@(path) containsString:[NSString stringWithFormat:@"/%@:", portNode]];
}
