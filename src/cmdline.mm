//
//  cmdline.mm
//
//  The command-line front end.
//
//  This runs in a process that never creates an NSApplication, so nothing here
//  may put up a window or expect a run loop to be turning. Each action writes
//  to stdout or stderr and returns the status the process exits with.
//
//  AppKit is still imported, because the generated Swift header below declares
//  classes that derive from it. Declaring those types costs nothing; it is
//  starting an application that this process must not do.
//

extern "C"
{
#import <getopt.h>
}

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "cmdline.h"
#import "utils.h"
#import "EZDisplay-Swift.h"

/// The most displays this tool will look at, matching the interface's limit.
static const uint32_t kMaxDisplays = 0x10;

/// Colour depth is reported as 32 for every mode. The field the old code read
/// this from stopped being meaningful on recent macOS, so the value is fixed
/// here rather than read back per mode.
static const int kBitsPerPixel = 32;

/// What the arguments asked for. Zero means "not given", which for the mode
/// filters also means "match anything".
struct CommandLineRequest
{
    int width;
    int height;
    CGFloat scale;
    int bitsPerPixel;
    int displayIndex;

    bool listDisplays;
    bool listModes;
    bool restoreAll;
};


static void PrintUsage()
{
    fprintf(stderr,
            "Commandline options\n"
            "  --width       (-w)  Width\n"
            "  --height      (-h)  Height\n"
            "  --scale       (-s)  Scale (2.0 = Retina, default=current)\n"
            "  --bits        (-b)  Color depth (default=current)\n"
            "  --display     (-d)  Select display # (default=main)\n"
            "  --displays    (-l)  List available displays\n"
            "  --modes       (-m)  List available modes\n"
            "  --restore-all (-r)  Remove EZDisplay's resolution overrides for every\n"
            "                      display, including disconnected ones, and exit\n");
}


/// Fills in `request` from the arguments. Returns false if an option was not
/// recognised, having already printed the usage text.
static bool ParseArguments(int argc, char *const *argv, CommandLineRequest &request)
{
    static struct option longOptions[] = {
        {"width",       required_argument, NULL, 'w'},
        {"height",      required_argument, NULL, 'h'},
        {"scale",       required_argument, NULL, 's'},
        {"bits",        required_argument, NULL, 'b'},
        {"display",     required_argument, NULL, 'd'},
        {"displays",    no_argument,       NULL, 'l'},
        {"modes",       no_argument,       NULL, 'm'},
        {"restore-all", no_argument,       NULL, 'r'},
        {NULL, 0, NULL, 0},
    };

    int option;
    while ((option = getopt_long(argc, argv, "w:h:s:b:d:lmr", longOptions, NULL)) != -1)
    {
        switch (option)
        {
            case 'w': request.width        = atoi(optarg); break;
            case 'h': request.height       = atoi(optarg); break;
            case 's': request.scale        = atof(optarg); break;
            case 'b': request.bitsPerPixel = atoi(optarg); break;
            case 'd': request.displayIndex = atoi(optarg); break;
            case 'l': request.listDisplays = true;         break;
            case 'm': request.listModes    = true;         break;
            case 'r': request.restoreAll   = true;         break;

            default:
                PrintUsage();
                return false;
        }
    }

    return true;
}


static void PrintMode(const char *label, const DisplayModeDescription &mode)
{
    fprintf(stdout, "%s: {resolution=%dx%d, scale = %.1f, freq = %d, bits/pixel = %d}\n",
            label, mode.width, mode.height, mode.scale, mode.refreshRate, kBitsPerPixel);
}


/// Whether `mode` satisfies every filter the caller actually gave. A filter
/// left at zero does not narrow anything.
static bool ModeMatches(const DisplayModeDescription &mode, const CommandLineRequest &request)
{
    if (request.width && mode.width != (uint32_t) request.width)
        return false;
    if (request.height && mode.height != (uint32_t) request.height)
        return false;
    if (request.bitsPerPixel && request.bitsPerPixel != kBitsPerPixel)
        return false;
    if (request.scale && mode.scale != request.scale)
        return false;

    return true;
}


/// Removes every override this app created, across all displays.
///
/// Nothing here needs a display attached, which is why it runs before the
/// display list is read: `uninstall` has to be able to call it whatever is
/// plugged in at the time.
static int RestoreEveryOverride()
{
    NSArray<NSString *> *ours = [RestoreSettingsItem managedOverrideRelativePaths];
    NSArray<NSString *> *theirs = [RestoreSettingsItem unmanagedOverrideRelativePaths];

    if (theirs.count > 0)
        fprintf(stdout, "Leaving %lu override file(s) alone: EZDisplay did not create them.\n",
                (unsigned long) theirs.count);

    if ([RestoreSettingsItem restoreAllScriptFor: ours] == nil)
    {
        fprintf(stdout, "EZDisplay has not created any display overrides; nothing to restore.\n");
        return 0;
    }

    NSDictionary *failure = [RestoreSettingsItem restoreAllSettings];
    if (failure != nil)
    {
        NSString *reason = failure[@"NSAppleScriptErrorBriefMessage"];
        fprintf(stderr, "Restore failed: %s\n", reason ? reason.UTF8String : "unknown error");
        return 1;
    }

    fprintf(stdout, "Removed the EZDisplay resolution overrides for %lu display(s).\n",
            (unsigned long) ours.count);
    return 0;
}


/// Prints the mode each attached display is running right now.
static int ListAttachedDisplays(const CGDirectDisplayID *displays, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++)
    {
        int modeNumber = 0;
        CGSGetCurrentDisplayMode(displays[i], &modeNumber);

        DisplayModeDescription mode;
        CGSGetDisplayModeDescriptionOfLength(displays[i], modeNumber, &mode,
                                             DisplayModeDescriptionLength);

        char label[32];
        snprintf(label, sizeof(label), "Display %u", i);
        PrintMode(label, mode);
    }

    return 0;
}


/// Prints every mode `display` offers that passes the filters.
static int ListModesForDisplay(CGDirectDisplayID display, const CommandLineRequest &request)
{
    int count = 0;
    DisplayModeDescription *modes = NULL;
    CopyDisplayModeDescriptions(display, &modes, &count);

    for (int i = 0; i < count; i++)
        if (ModeMatches(modes[i], request))
            PrintMode("mode", modes[i]);

    free(modes);
    return 0;
}


/// Switches `display` to the first mode matching the request.
///
/// Anything the caller left out is taken from the mode the display is running
/// now, so `--width` on its own changes the width and keeps the rest.
static int ApplyRequestedMode(CGDirectDisplayID display, CommandLineRequest request)
{
    int currentModeNumber = 0;
    CGSGetCurrentDisplayMode(display, &currentModeNumber);

    DisplayModeDescription current;
    CGSGetDisplayModeDescriptionOfLength(display, currentModeNumber, &current,
                                         DisplayModeDescriptionLength);

    if (!request.width && !request.height)
    {
        request.width = (int) current.width;
        request.height = (int) current.height;
    }
    if (!request.scale)
        request.scale = current.scale;
    if (!request.bitsPerPixel)
        request.bitsPerPixel = kBitsPerPixel;

    int count = 0;
    DisplayModeDescription *modes = NULL;
    CopyDisplayModeDescriptions(display, &modes, &count);

    int chosen = -1;
    for (int i = 0; i < count && chosen < 0; i++)
        if (ModeMatches(modes[i], request))
            chosen = i;

    if (chosen >= 0)
        ApplyDisplayModeNumber(display, chosen);
    else
        fprintf(stderr, "Error: could not select a new mode\n");

    free(modes);

    // Note: this returns success even when no mode matched, which is what the
    // tool has always done. Changing it would change the exit status scripts
    // see, so it is left alone here and dealt with when the command line is
    // reworked into subcommands.
    return 0;
}


int RunCommandLine(int argc, char *const *argv)
{
    CommandLineRequest request = {};

    if (!ParseArguments(argc, argv, request))
        return -1;

    if (request.restoreAll)
        return RestoreEveryOverride();

    CGDirectDisplayID displays[kMaxDisplays];
    uint32_t attached = 0;
    CGGetOnlineDisplayList(kMaxDisplays, displays, &attached);

    if (request.displayIndex < 0 || (uint32_t) request.displayIndex >= attached)
    {
        fprintf(stderr, "Error: display index %d exceeds display count %u\n",
                request.displayIndex, attached);
        return 1;
    }

    CGDirectDisplayID display = displays[request.displayIndex];

    if (request.listDisplays)
        return ListAttachedDisplays(displays, attached);

    if (request.listModes)
        return ListModesForDisplay(display, request);

    return ApplyRequestedMode(display, request);
}
