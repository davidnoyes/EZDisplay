//
//  cmdline.mm
//
//  The command-line front end: the part that touches displays.
//
//  Every decision this file makes before it touches one — what the arguments
//  asked for, which display they meant, which mode satisfies them — is in
//  CommandPlan.h, where it is tested. What is left here is reading the display
//  state through the private services, calling the same bridges the menu calls,
//  and printing the result.
//
//  This runs in a process that never creates an NSApplication, so nothing here
//  may put up a window or expect a run loop to be turning. That is why the
//  confirm-or-revert countdown below polls stdin itself rather than reusing
//  SafeApply, which is an AppKit panel driven by a Timer.
//
//  AppKit is still imported, because the generated Swift header below declares
//  classes that derive from it. Declaring those types costs nothing; it is
//  starting an application that this process must not do.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import <poll.h>
#import <signal.h>
#import <unistd.h>

#import "cmdline.h"
#import "CommandPlan.h"
#import "ColorMode.h"
#import "CoreBrightness.h"
#import "DDC.h"
#import "DDCProtocol.h"
#import "DisplayModes.h"
#import "DisplayServices.h"
#import "utils.h"
#import "EZDisplay-Swift.h"

/// The most displays this tool will look at, matching the interface's limit.
static const uint32_t kMaxDisplays = 0x10;

/// How long a change waits to be confirmed before it is put back. The same 20
/// seconds the GUI allows, for the same reason: long enough to find the
/// keyboard on a display you can no longer read, short enough not to strand
/// someone who has walked away.
static const int kConfirmSeconds = 20;

/// Set by the interrupt handlers below. A change waiting to be confirmed is
/// reverted on the way out, because Ctrl-C from someone staring at a black
/// screen means "undo this", not "leave it and quit".
static volatile sig_atomic_t gInterrupted = 0;

static void NoteInterrupt(int signal)
{
    gInterrupted = signal;
}


#pragma mark - Reading the version

/// What `version` prints, read out of the bundle this binary lives in.
///
/// Deliberately not `mainBundle`, which is derived from the path the process
/// was started with rather than from where the executable really is. Reached
/// through the symlink the Homebrew cask puts on PATH, that resolves to
/// /opt/homebrew/bin, whose Info.plist does not exist, and both keys below come
/// back nil — so `ezdisplay --version` printed no version at all for anyone who
/// installed it the documented way. `bundleForClass:` is derived from the image
/// the class was compiled into, which is this binary however it was reached.
static std::string VersionText()
{
    NSBundle *bundle = [NSBundle bundleForClass: [EZDisplays class]];

    NSString *shortVersion = [bundle objectForInfoDictionaryKey: @"CFBundleShortVersionString"];
    NSString *build        = [bundle objectForInfoDictionaryKey: @"CFBundleVersion"];

    return EZVersionText(shortVersion.UTF8String ?: "", build.UTF8String ?: "");
}


#pragma mark - Reading the display state

/// The attached displays, in the order the interface reports them.
static std::vector<CGDirectDisplayID> AttachedDisplays()
{
    CGDirectDisplayID ids[kMaxDisplays];
    uint32_t count = 0;
    CGGetOnlineDisplayList(kMaxDisplays, ids, &count);

    return std::vector<CGDirectDisplayID>(ids, ids + count);
}


/// The same displays as the pure layer sees them: an index to select one by,
/// and the vendor and product pair to select one by name.
static std::vector<EZDisplayIdentity> Identities(const std::vector<CGDirectDisplayID> &displays)
{
    std::vector<EZDisplayIdentity> identities;

    for (size_t i = 0; i < displays.size(); i++) {
        EZDisplayIdentity identity;
        identity.index   = (int) i;
        identity.vendor  = CGDisplayVendorNumber(displays[i]);
        identity.product = CGDisplayModelNumber(displays[i]);
        identity.isMain  = CGDisplayIsMain(displays[i]) != 0;
        identities.push_back(identity);
    }

    return identities;
}


static EZModeCandidate CandidateFrom(const DisplayModeDescription &mode)
{
    EZModeCandidate candidate;
    candidate.number    = (int) mode.number;
    candidate.width     = (int) mode.width;
    candidate.height    = (int) mode.height;
    candidate.refreshHz = (int) mode.refreshRate;
    candidate.scale     = mode.scale;
    return candidate;
}


/// Every mode `display` offers, and the one it is running.
static void ReadModes(CGDirectDisplayID display,
                      std::vector<EZModeCandidate> *modes, EZModeCandidate *current)
{
    int currentNumber = 0;
    CGSGetCurrentDisplayMode(display, &currentNumber);

    DisplayModeDescription currentMode = {};
    CGSGetDisplayModeDescriptionOfLength(display, currentNumber, &currentMode,
                                         DisplayModeDescriptionLength);
    *current = CandidateFrom(currentMode);

    int count = 0;
    DisplayModeDescription *list = NULL;
    CopyDisplayModeDescriptions(display, &list, &count);

    modes->clear();
    for (int i = 0; i < count; i++)
        modes->push_back(CandidateFrom(list[i]));

    free(list);
}


#pragma mark - Confirm or revert

/// Puts the change to the user and undoes it unless they keep it.
///
/// The change has already been applied when this is called: what is being
/// confirmed is a display the user can look at, which is the whole point of
/// applying first and asking after. Everything that is not a deliberate yes
/// reverts — the timeout, end of input, an unrecognized answer, Ctrl-C, and the
/// terminal going away — because a user who cannot read the screen cannot type
/// an answer either, and waiting has to be the thing that undoes it.
///
/// A script has nobody to answer, so it is not asked; see `EZShouldPrompt`.
static int ConfirmOrRevert(const EZCommandRequest &request, const char *detail,
                           void (^revert)(void))
{
    const bool interactive = isatty(STDIN_FILENO) && isatty(STDERR_FILENO);
    if (!EZShouldPrompt(request.force, interactive)) {
        fprintf(stdout, "%s\n", detail);
        return EZExitKept;
    }

    struct sigaction action = {};
    struct sigaction previousINT = {}, previousHUP = {};
    action.sa_handler = NoteInterrupt;
    // No SA_RESTART, deliberately: the poll below has to come back so the
    // countdown can notice the signal and revert.
    sigaction(SIGINT, &action, &previousINT);
    sigaction(SIGHUP, &action, &previousHUP);

    gInterrupted = 0;
    bool keep = false;

    for (int remaining = kConfirmSeconds; remaining > 0 && !gInterrupted; remaining--) {
        fprintf(stderr, "\r%s. Keep it? [y/N] reverting in %2ds ", detail, remaining);
        fflush(stderr);

        struct pollfd waiting = { STDIN_FILENO, POLLIN, 0 };
        int ready = poll(&waiting, 1, 1000);

        if (ready < 0)
            break;          // interrupted, or something is wrong with stdin
        if (ready == 0)
            continue;       // another second gone

        char answer[64];
        keep = EZAnswerKeeps(fgets(answer, sizeof(answer), stdin));
        break;
    }

    fprintf(stderr, "\r%*s\r", 78, "");
    fflush(stderr);

    sigaction(SIGINT, &previousINT, NULL);
    sigaction(SIGHUP, &previousHUP, NULL);

    if (keep) {
        fprintf(stdout, "%s\n", detail);
        return EZExitKept;
    }

    revert();
    fprintf(stderr, "Reverted: %s\n", detail);

    // A signal that arrived while the question was up has been handled — the
    // change is undone — so the process exits on its own terms rather than
    // re-raising and losing the exit code that says what happened.
    return EZExitReverted;
}


#pragma mark - The commands

static int ListDisplays(const std::vector<CGDirectDisplayID> &displays,
                        const EZCommandRequest &request)
{
    std::vector<std::string> objects;

    for (size_t i = 0; i < displays.size(); i++) {
        CGDirectDisplayID display = displays[i];

        std::vector<EZModeCandidate> modes;
        EZModeCandidate current;
        ReadModes(display, &modes, &current);

        const uint32_t vendor  = CGDisplayVendorNumber(display);
        const uint32_t product = CGDisplayModelNumber(display);
        const bool capable = [EZColorModes supportsHDRForDisplay: display];
        const bool enabled = capable && [EZColorModes isHDREnabledForDisplay: display];
        NSString *name = [EZDisplays nameForDisplay: display index: (int) i];

        // The pair as --display takes it back, so a script can select a display
        // with a field it just read rather than by assembling one.
        char selector[32];
        snprintf(selector, sizeof(selector), "0x%04x:0x%04x", vendor, product);

        if (!request.json) {
            fprintf(stdout, "%zu  %s  %-28s %4dx%-4d @ %3dHz  scale %.1f  HDR %s\n",
                    i, selector, name.UTF8String,
                    current.width, current.height, current.refreshHz, current.scale,
                    !capable ? "-" : enabled ? "on" : "off");
            continue;
        }

        EZJSONObject object;
        object.addInt("index", (long) i);
        object.addString("selector", selector);
        object.addInt("vendor", vendor);
        object.addInt("product", product);
        object.addString("name", name.UTF8String);
        object.addInt("width", current.width);
        object.addInt("height", current.height);
        object.addInt("refresh", current.refreshHz);
        object.addNumber("scale", current.scale);
        object.addBool("hdrCapable", capable);
        object.addBool("hdrEnabled", enabled);
        objects.push_back(object.text());
    }

    if (request.json)
        fprintf(stdout, "%s\n", EZJSONArray(objects).c_str());

    return EZExitKept;
}


static int ListModes(CGDirectDisplayID display, const EZCommandRequest &request)
{
    std::vector<EZModeCandidate> modes;
    EZModeCandidate current;
    ReadModes(display, &modes, &current);

    std::vector<EZModeCandidate> shown = EZDedupeModes(EZFilterModes(modes, request));

    if (request.json) {
        std::vector<std::string> objects;
        for (const EZModeCandidate &mode : shown) {
            EZJSONObject object;
            object.addInt("width", mode.width);
            object.addInt("height", mode.height);
            object.addInt("refresh", mode.refreshHz);
            object.addNumber("scale", mode.scale);
            object.addBool("current", EZSameMode(mode, current));
            objects.push_back(object.text());
        }
        fprintf(stdout, "%s\n", EZJSONArray(objects).c_str());
    } else {
        for (const EZModeCandidate &mode : shown)
            fprintf(stdout, "%s %4dx%-4d @ %3dHz  scale %.1f\n",
                    EZSameMode(mode, current) ? "*" : " ",
                    mode.width, mode.height, mode.refreshHz, mode.scale);
    }

    // Reported after the listing rather than instead of it, so --json still
    // prints something a parser accepts while the exit code stays the same as
    // the one a human gets for the same question.
    if (shown.empty()) {
        fprintf(stderr, "No mode matches those filters.\n");
        return EZExitFailed;
    }

    return EZExitKept;
}


static int SetMode(CGDirectDisplayID display, const EZCommandRequest &request)
{
    std::vector<EZModeCandidate> modes;
    EZModeCandidate current;
    ReadModes(display, &modes, &current);

    int chosen = EZChooseMode(modes, request, current);
    if (chosen < 0) {
        fprintf(stderr, "No mode matches that request. Try: ezdisplay modes\n");
        return EZExitFailed;
    }

    if (chosen == current.number) {
        fprintf(stdout, "Already %dx%d @ %dHz, scale %.1f\n",
                current.width, current.height, current.refreshHz, current.scale);
        return EZExitKept;
    }

    if (![EZDisplays setModeNum: chosen forDisplay: display]) {
        fprintf(stderr, "The display refused that mode.\n");
        return EZExitFailed;
    }

    // Read the mode back rather than describing the one asked for: the request
    // is a partial description, and macOS may not have landed exactly where the
    // chosen entry said.
    std::vector<EZModeCandidate> after;
    EZModeCandidate applied;
    ReadModes(display, &after, &applied);

    char detail[128];
    snprintf(detail, sizeof(detail), "%dx%d @ %dHz, scale %.1f",
             applied.width, applied.height, applied.refreshHz, applied.scale);

    const int previous = current.number;
    return ConfirmOrRevert(request, detail, ^{
        [EZDisplays setModeNum: previous forDisplay: display];
    });
}


static int SetHDR(CGDirectDisplayID display, const EZCommandRequest &request)
{
    if (![EZColorModes supportsHDRForDisplay: display]) {
        fprintf(stderr, "This display cannot do HDR where it is now.\n");
        return EZExitFailed;
    }

    const BOOL wanted = request.on;
    if (wanted == [EZColorModes isHDREnabledForDisplay: display]) {
        fprintf(stdout, "HDR is already %s.\n", wanted ? "on" : "off");
        return EZExitKept;
    }

    if (![EZColorModes setHDREnabled: wanted forDisplay: display]) {
        fprintf(stderr, "Could not change HDR on this display.\n");
        return EZExitFailed;
    }

    return ConfirmOrRevert(request, wanted ? "HDR on" : "HDR off", ^{
        [EZColorModes setHDREnabled: !wanted forDisplay: display];
    });
}


static int SetMirroring(const EZCommandRequest &request)
{
    const BOOL wanted = request.on;
    if (wanted == CGDisplayIsInMirrorSet(CGMainDisplayID())) {
        fprintf(stdout, "Mirroring is already %s.\n", wanted ? "on" : "off");
        return EZExitKept;
    }

    CGError error = [EZDisplays setMirroring: wanted];
    if (error != kCGErrorSuccess) {
        fprintf(stderr, "Cannot mirror displays: %s (%d)\n",
                DisplayErrorName(error).UTF8String, error);
        return EZExitFailed;
    }

    return ConfirmOrRevert(request, wanted ? "Mirroring on" : "Mirroring off", ^{
        [EZDisplays setMirroring: !wanted];
    });
}


// Night Shift and True Tone are settings of the machine rather than of one
// display, so nothing below takes a display, and neither can black out the
// screen, so neither goes through ConfirmOrRevert. Both read back the moment
// they are written, which is why a change is reported from what was asked for
// rather than from a second read.

/// A minute count as the `HH:MM` the command line reads back in.
static std::string ClockTime(NSInteger minute)
{
    char text[6];
    snprintf(text, sizeof(text), "%02d:%02d", (int) (minute / 60), (int) (minute % 60));
    return text;
}


static int ShowNightShift(const EZCommandRequest &request)
{
    if (![EZNightShift supported]) {
        fprintf(stderr, "Night Shift is not available on this Mac.\n");
        return EZExitFailed;
    }

    const BOOL on = [EZNightShift enabled];
    const int warmth = [EZNightShift warmthPercent];
    if (warmth < 0) {
        fprintf(stderr, "Cannot read the Night Shift warmth.\n");
        return EZExitFailed;
    }

    const EZNightShiftState state = [EZNightShift state];
    // The schedule that `scheduled` would run, which is the one in force where
    // there is one and the remembered choice where there is not, so the report
    // and the menu agree about what the third state means.
    const EZNightShiftMode scheduleMode = [EZPrefs resolvedNightShiftSchedule];
    NSInteger from = 0, to = 0;
    if (![EZNightShift getScheduleFrom: &from to: &to]) {
        // Checked rather than assumed, because a refused read leaves the pair at
        // zero and midnight to midnight would be reported as a real window.
        fprintf(stderr, "Cannot read the Night Shift schedule.\n");
        return EZExitFailed;
    }

    if (request.json) {
        EZJSONObject object;
        object.addBool("enabled", on);
        object.addInt("warmth", warmth);
        object.addString("state", state == EZNightShiftScheduled     ? "scheduled"
                                : state == EZNightShiftUntilTomorrow ? "until-tomorrow"
                                                                     : "off");
        object.addString("schedule",
                         scheduleMode == EZNightShiftModeSunset ? "sunset" : "custom");
        // The window is reported whichever schedule is chosen, because the
        // daemon keeps it either way and it is what custom would go back to.
        object.addString("scheduleFrom", ClockTime(from));
        object.addString("scheduleTo", ClockTime(to));
        fprintf(stdout, "%s\n", object.text().c_str());
        return EZExitKept;
    }

    // The warmth is shown whether it is on or not, because it is what turning
    // it on would give you.
    switch (state) {
        case EZNightShiftOff:
            fprintf(stdout, "Night Shift is off, warmth %d%%.\n", warmth);
            break;
        case EZNightShiftUntilTomorrow:
            fprintf(stdout, "Night Shift is on until tomorrow, warmth %d%%.\n", warmth);
            break;
        case EZNightShiftScheduled:
            // Both halves, because the schedule alone does not say whether the
            // tint is on this minute and the tint alone does not say why.
            fprintf(stdout, "Night Shift is scheduled %s, %s now, warmth %d%%.\n",
                    [EZNightShift descriptionOfScheduleMode: scheduleMode].UTF8String,
                    on ? "on" : "off", warmth);
            break;
    }
    return EZExitKept;
}


static int SetNightShift(const EZCommandRequest &request)
{
    if (![EZNightShift supported]) {
        fprintf(stderr, "Night Shift is not available on this Mac.\n");
        return EZExitFailed;
    }

    if (request.toggleAction == EZToggleActionWarmth) {
        if (![EZNightShift setWarmthPercent: request.warmthPercent]) {
            fprintf(stderr, "Cannot set the Night Shift warmth.\n");
            return EZExitFailed;
        }
        // Said plainly, because setting the warmth does not switch Night Shift
        // on and a caller who expected it to would otherwise see a success
        // message and no change on screen.
        fprintf(stdout, "Night Shift warmth %d%%%s\n", request.warmthPercent,
                [EZNightShift enabled] ? "." : ". Night Shift is off.");
        return EZExitKept;
    }

    if (request.toggleAction == EZToggleActionSchedule) {
        const EZNightShiftMode wanted = request.scheduleKind == EZScheduleSunset
                                      ? EZNightShiftModeSunset : EZNightShiftModeCustom;

        // Refused rather than stored, because a sunset schedule this Mac is not
        // allowed to run would sit in the Preferences popup looking chosen and
        // never turn the tint on. System Settings drops the choice for the same
        // reason.
        if (wanted == EZNightShiftModeSunset && ![EZNightShift sunSchedulePermitted]) {
            fprintf(stderr, "Sunset to sunrise needs location services, which are off "
                            "for Night Shift. Set a window instead, for example: "
                            "ezdisplay nightshift schedule 22:00-07:00\n");
            return EZExitFailed;
        }

        // The window before the kind: setting the kind applies it when a
        // schedule is already running, and applying the old window first would
        // tint on last night's hours for as long as it took to write the new
        // one.
        if (wanted == EZNightShiftModeCustom &&
            ![EZNightShift setScheduleFrom: request.scheduleFrom to: request.scheduleTo]) {
            fprintf(stderr, "Cannot set the Night Shift schedule.\n");
            return EZExitFailed;
        }

        [EZPrefs setResolvedNightShiftSchedule: wanted];

        // Said plainly when nothing is running it, for the same reason the
        // warmth message says so: the command succeeded and the screen did not
        // change, which reads as a failure without a word about it.
        fprintf(stdout, "Night Shift schedule %s%s\n",
                [EZNightShift descriptionOfScheduleMode: wanted].UTF8String,
                [EZNightShift state] == EZNightShiftScheduled
                    ? "." : ". Night Shift is not running it: ezdisplay nightshift scheduled");
        return EZExitKept;
    }

    const EZNightShiftState wanted =
        request.toggleAction == EZToggleActionScheduled ? EZNightShiftScheduled
                              : request.on              ? EZNightShiftUntilTomorrow
                                                        : EZNightShiftOff;
    static const char *const names[] = {"off", "on until tomorrow", "scheduled"};

    if (wanted == [EZNightShift state]) {
        fprintf(stdout, "Night Shift is already %s.\n", names[wanted]);
        return EZExitKept;
    }

    const EZNightShiftMode scheduleMode = [EZPrefs resolvedNightShiftSchedule];
    if (![EZNightShift setState: wanted scheduleMode: scheduleMode]) {
        fprintf(stderr, "Cannot set Night Shift %s.\n", names[wanted]);
        return EZExitFailed;
    }

    if (wanted != EZNightShiftScheduled) {
        fprintf(stdout, "Night Shift %s.\n", names[wanted]);
        return EZExitKept;
    }

    fprintf(stdout, "Night Shift scheduled %s.\n",
            [EZNightShift descriptionOfScheduleMode: scheduleMode].UTF8String);
    return EZExitKept;
}


static int ShowTrueTone(const EZCommandRequest &request)
{
    if (![EZTrueTone available]) {
        fprintf(stderr, "True Tone is not available: no attached display has the sensor for it.\n");
        return EZExitFailed;
    }

    const BOOL on = [EZTrueTone enabled];

    if (request.json) {
        EZJSONObject object;
        object.addBool("enabled", on);
        fprintf(stdout, "%s\n", object.text().c_str());
        return EZExitKept;
    }

    fprintf(stdout, "True Tone is %s.\n", on ? "on" : "off");
    return EZExitKept;
}


static int SetTrueTone(const EZCommandRequest &request)
{
    if (![EZTrueTone available]) {
        fprintf(stderr, "True Tone is not available: no attached display has the sensor for it.\n");
        return EZExitFailed;
    }

    const BOOL wanted = request.on;
    if (wanted == [EZTrueTone enabled]) {
        fprintf(stdout, "True Tone is already %s.\n", wanted ? "on" : "off");
        return EZExitKept;
    }

    if (![EZTrueTone setEnabled: wanted]) {
        fprintf(stderr, "Cannot turn True Tone %s.\n", wanted ? "on" : "off");
        return EZExitFailed;
    }

    fprintf(stdout, "True Tone %s.\n", wanted ? "on" : "off");
    return EZExitKept;
}


/// Why this display cannot be dimmed, or null when it can.
///
/// The two reasons are worth telling apart. A missing framework symbol is this
/// build failing on a macOS it was not written for, and every display is then
/// out of reach; a display that reports it cannot change is the ordinary case
/// of a monitor macOS does not drive, and the rest still work.
///
/// Worded for both callers rather than for the one that sets. The capability is
/// a single thing — a display macOS does not drive cannot be read either — so
/// saying "cannot set" would have told someone who asked what the brightness is
/// about a write they never attempted.
static const char *WhyNoBrightness(CGDirectDisplayID display)
{
    if (![EZBrightness supported])
        return "this version of macOS does not offer the brightness controls "
               "EZDisplay uses";
    if (![EZBrightness availableForDisplay: display])
        return "macOS does not control this display's brightness. Use the "
               "monitor's own buttons";
    return NULL;
}


static int ShowBrightness(CGDirectDisplayID display, const EZCommandRequest &request)
{
    if (const char *why = WhyNoBrightness(display)) {
        fprintf(stderr, "No brightness: %s.\n", why);
        return EZExitFailed;
    }

    const NSInteger percent = [EZBrightness percentForDisplay: display];
    if (percent < 0) {
        fprintf(stderr, "Cannot read this display's brightness.\n");
        return EZExitFailed;
    }

    if (request.json) {
        EZJSONObject object;
        object.addInt("percent", (long) percent);
        fprintf(stdout, "%s\n", object.text().c_str());
        return EZExitKept;
    }

    fprintf(stdout, "Brightness is %ld%%.\n", (long) percent);
    return EZExitKept;
}


static int SetBrightnessPercent(CGDirectDisplayID display, const EZCommandRequest &request)
{
    if (const char *why = WhyNoBrightness(display)) {
        fprintf(stderr, "No brightness: %s.\n", why);
        return EZExitFailed;
    }

    if (![EZBrightness setPercent: request.brightnessPercent forDisplay: display]) {
        fprintf(stderr, "Cannot set this display's brightness to %d%%.\n",
                request.brightnessPercent);
        return EZExitFailed;
    }

    // Read back rather than reporting what was asked for. The framework rounds
    // to a step of its own choosing on some panels, and printing the request
    // would claim a value the display is not at. There is no confirm-or-revert
    // here for the same reason the two toggles have none: no brightness blanks
    // the screen for good, and the next command puts it back.
    const NSInteger now = [EZBrightness percentForDisplay: display];
    fprintf(stdout, "Brightness is %ld%%.\n",
            (long) (now < 0 ? request.brightnessPercent : now));
    return EZExitKept;
}


/// Why this monitor's speakers cannot be reached over DDC, or null when they
/// can. `code` names the one being asked for, so mute and volume each report
/// their own: a monitor can implement one and not the other.
///
/// Worded for both callers, as `WhyNoBrightness` is, and for the same reason: a
/// display that will not answer a read will not take a write either.
static const char *WhyNoAudio(CGDirectDisplayID display, uint8_t code)
{
    if (![EZDisplayAudio supported])
        return "this version of macOS does not offer the DDC calls EZDisplay uses";

    const BOOL available = code == EZVCPAudioMute
                         ? [EZDisplayAudio muteAvailableForDisplay: display]
                         : [EZDisplayAudio availableForDisplay: display];
    if (!available)
        return "this monitor does not report that control over DDC. Use its own "
               "buttons, or check that it has speakers at all";
    return NULL;
}


static int ShowVolume(CGDirectDisplayID display, const EZCommandRequest &request)
{
    if (const char *why = WhyNoAudio(display, EZVCPSpeakerVolume)) {
        fprintf(stderr, "No volume: %s.\n", why);
        return EZExitFailed;
    }

    const NSInteger percent = [EZDisplayAudio percentForDisplay: display];
    if (percent < 0) {
        fprintf(stderr, "Cannot read this monitor's volume.\n");
        return EZExitFailed;
    }

    if (request.json) {
        EZJSONObject object;
        object.addInt("percent", (long) percent);
        fprintf(stdout, "%s\n", object.text().c_str());
        return EZExitKept;
    }

    fprintf(stdout, "Volume is %ld%%.\n", (long) percent);
    return EZExitKept;
}


static int SetVolumePercent(CGDirectDisplayID display, const EZCommandRequest &request)
{
    if (const char *why = WhyNoAudio(display, EZVCPSpeakerVolume)) {
        fprintf(stderr, "No volume: %s.\n", why);
        return EZExitFailed;
    }

    // A false answer here is a write the monitor did not take, not a write that
    // failed to go out — every set is read back. Saying which is the difference
    // between a bug to chase and a monitor that owns its own dial.
    if (![EZDisplayAudio setPercent: request.volumePercent forDisplay: display]) {
        fprintf(stderr, "This monitor did not take a volume of %d%%. It reported "
                        "the write and left the dial where it was.\n",
                request.volumePercent);
        return EZExitFailed;
    }

    // Read back rather than reporting what was asked for, as brightness does.
    // A display whose dial steps in twos lands on 52 for a request of 51, and
    // printing 51 would name a value it is not at.
    const NSInteger now = [EZDisplayAudio percentForDisplay: display];
    fprintf(stdout, "Volume is %ld%%.\n",
            (long) (now < 0 ? request.volumePercent : now));
    return EZExitKept;
}


static int ShowMute(CGDirectDisplayID display, const EZCommandRequest &request)
{
    if (const char *why = WhyNoAudio(display, EZVCPAudioMute)) {
        fprintf(stderr, "No mute: %s.\n", why);
        return EZExitFailed;
    }

    const NSInteger muted = [EZDisplayAudio mutedForDisplay: display];
    if (muted < 0) {
        fprintf(stderr, "Cannot read whether this monitor is muted.\n");
        return EZExitFailed;
    }

    if (request.json) {
        EZJSONObject object;
        object.addBool("muted", muted == 1);
        fprintf(stdout, "%s\n", object.text().c_str());
        return EZExitKept;
    }

    fprintf(stdout, "Mute is %s.\n", muted == 1 ? "on" : "off");
    return EZExitKept;
}


static int SetMute(CGDirectDisplayID display, const EZCommandRequest &request)
{
    if (const char *why = WhyNoAudio(display, EZVCPAudioMute)) {
        fprintf(stderr, "No mute: %s.\n", why);
        return EZExitFailed;
    }

    if (![EZDisplayAudio setMuted: request.on forDisplay: display]) {
        fprintf(stderr, "This monitor did not take mute %s.\n",
                request.on ? "on" : "off");
        return EZExitFailed;
    }

    fprintf(stdout, "Mute %s.\n", request.on ? "on" : "off");
    return EZExitKept;
}


static int ListColorModes(CGDirectDisplayID display, const EZCommandRequest &request)
{
    NSArray<EZColorMode *> *modes = [EZColorModes supportedForDisplay: display];

    if (request.json) {
        std::vector<std::string> objects;
        for (EZColorMode *mode in modes) {
            EZJSONObject object;
            object.addInt("elementID", mode.elementID);
            object.addString("label", mode.label.UTF8String);
            object.addBool("current", mode.isCurrent);
            objects.push_back(object.text());
        }
        fprintf(stdout, "%s\n", EZJSONArray(objects).c_str());
    } else {
        for (EZColorMode *mode in modes)
            fprintf(stdout, "%s %3d  %s\n",
                    mode.isCurrent ? "*" : " ", mode.elementID, mode.label.UTF8String);
    }

    if (modes.count == 0) {
        fprintf(stderr, "This display reports no color modes.\n");
        return EZExitFailed;
    }

    return EZExitKept;
}


static int SetColorMode(CGDirectDisplayID display, const EZCommandRequest &request)
{
    // Asked for the mode it is already on. The apply call cannot say so — it
    // returns nothing for that and for an element the display does not offer
    // alike — and a script that sets a mode to be sure of it should hear that
    // nothing needed doing, not that the command failed.
    EZColorMode *inUse = [EZColorModes currentForDisplay: display];
    if (inUse && inUse.elementID == request.elementID) {
        fprintf(stdout, "Already color mode %d: %s\n",
                request.elementID, inUse.label.UTF8String);
        return EZExitKept;
    }

    EZColorModeRestorePoint *point = [EZColorModes applyElementID: request.elementID
                                                        toDisplay: display];
    if (point == nil) {
        fprintf(stderr, "Element %d is not a color mode this display offers at its current "
                        "timing, or it describes the mode already in force. "
                        "Try: ezdisplay color list\n",
                request.elementID);
        return EZExitFailed;
    }

    EZColorMode *applied = [EZColorModes currentForDisplay: display];

    char detail[256];
    snprintf(detail, sizeof(detail), "Color mode %d: %s", request.elementID,
             applied ? applied.label.UTF8String : "applied");

    return ConfirmOrRevert(request, detail, ^{
        if ([EZColorModes restore: point] == EZColorModeChangeFailed)
            fprintf(stderr, "The display is still on the color mode EZDisplay applied.\n");
    });
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
        fprintf(stdout, "Leaving %lu override %s alone: EZDisplay did not create %s.\n",
                (unsigned long) theirs.count,
                theirs.count == 1 ? "file" : "files",
                theirs.count == 1 ? "it" : "them");

    if ([RestoreSettingsItem restoreAllScriptFor: ours] == nil) {
        fprintf(stdout, "EZDisplay has not created any display overrides; nothing to restore.\n");
        return EZExitKept;
    }

    NSDictionary *failure = [RestoreSettingsItem restoreAllSettings];
    if (failure != nil) {
        NSString *reason = failure[@"NSAppleScriptErrorBriefMessage"];
        fprintf(stderr, "Restore failed: %s\n", reason ? reason.UTF8String : "unknown error");
        return EZExitFailed;
    }

    fprintf(stdout, "Removed the EZDisplay resolution overrides for %lu %s.\n",
            (unsigned long) ours.count,
            ours.count == 1 ? "display" : "displays");
    return EZExitKept;
}


/// Removes one display's override, putting back whatever was there before this
/// app first wrote to the file.
static int RestoreOneOverride(CGDirectDisplayID display, int index)
{
    NSString *name = [EZDisplays nameForDisplay: display index: index];
    RestoreSettingsItem *item =
        [[RestoreSettingsItem alloc] initWithTitle: name
                                            action: @selector(restoreSettings)
                                          vendorID: CGDisplayVendorNumber(display)
                                         productID: CGDisplayModelNumber(display)
                                       displayName: name];

    NSDictionary *failure = [item restoreSettings];
    if (failure != nil) {
        NSString *reason = failure[@"NSAppleScriptErrorBriefMessage"];
        fprintf(stderr, "Restore failed: %s\n", reason ? reason.UTF8String : "unknown error");
        return EZExitFailed;
    }

    fprintf(stdout, "Restored the display settings for %s.\n", name.UTF8String);
    return EZExitKept;
}


#pragma mark - Custom resolutions

/// The store for one display, which is the object the Preferences window edits
/// too: both ends write the same override file, with the same provenance keys,
/// so `restore` can still tell EZDisplay's files from anything else's.
static CustomResolutionsStore *StoreFor(CGDirectDisplayID display, int index)
{
    return [[CustomResolutionsStore alloc]
               initWithVendorID: CGDisplayVendorNumber(display)
                      productID: CGDisplayModelNumber(display)
                    displayName: [EZDisplays nameForDisplay: display index: index]];
}


/// Writes the list back. Needs an administrator password, and the resolution
/// does not appear until the display reconnects, because macOS reads the
/// override file when it enumerates the display rather than on every change.
static int SaveCustomResolutions(CustomResolutionsStore *store,
                                 NSArray<Resolution *> *resolutions, const char *detail)
{
    NSDictionary *failure = [store save: resolutions];
    if (failure != nil) {
        NSString *reason = failure[@"NSAppleScriptErrorBriefMessage"];
        fprintf(stderr, "Could not write the display override: %s\n",
                reason ? reason.UTF8String : "unknown error");
        return EZExitFailed;
    }

    fprintf(stdout, "%s. It takes effect when the display reconnects or the machine "
                    "restarts.\n", detail);
    return EZExitKept;
}


static int ListCustomResolutions(CGDirectDisplayID display, int index,
                                 const EZCommandRequest &request)
{
    // Largest first, which is the order the store writes them back in. The
    // plist holds them in whatever order they were added, and on a display with
    // a hundred of them that is not a listing anybody can read.
    NSArray<NSSortDescriptor *> *order = @[
        [NSSortDescriptor sortDescriptorWithKey: @"width"  ascending: NO],
        [NSSortDescriptor sortDescriptorWithKey: @"height" ascending: NO],
        [NSSortDescriptor sortDescriptorWithKey: @"HiDPI"  ascending: NO],
    ];
    NSArray<Resolution *> *resolutions =
        [[StoreFor(display, index) load] sortedArrayUsingDescriptors: order];

    if (request.json) {
        std::vector<std::string> objects;
        for (Resolution *resolution in resolutions) {
            EZJSONObject object;
            object.addInt("width", resolution.width);
            object.addInt("height", resolution.height);
            object.addBool("hidpi", resolution.HiDPI);
            objects.push_back(object.text());
        }
        fprintf(stdout, "%s\n", EZJSONArray(objects).c_str());
        return EZExitKept;
    }

    // Having none is an ordinary state rather than a failure: it is what every
    // display reports until someone adds one.
    if (resolutions.count == 0) {
        fprintf(stdout, "This display has no custom resolutions.\n");
        return EZExitKept;
    }

    for (Resolution *resolution in resolutions)
        fprintf(stdout, "%4ux%-4u  %s\n", resolution.width, resolution.height,
                resolution.HiDPI ? "HiDPI" : "standard");

    return EZExitKept;
}


static int AddCustomResolution(CGDirectDisplayID display, int index,
                               const EZCommandRequest &request)
{
    CustomResolutionsStore *store = StoreFor(display, index);
    NSMutableArray<Resolution *> *resolutions = [[store load] mutableCopy];

    const uint32_t width  = (uint32_t) request.width;
    const uint32_t height = (uint32_t) request.height;

    for (Resolution *resolution in resolutions)
        if (resolution.width == width && resolution.height == height
            && resolution.HiDPI == request.hiDPI) {
            fprintf(stdout, "%ux%u %s is already a custom resolution for this display.\n",
                    width, height, request.hiDPI ? "HiDPI" : "standard");
            return EZExitKept;
        }

    Resolution *added = [[Resolution alloc] init];
    // The flag first: it decides whether the size is stored as asked for or at
    // twice that, so setting it afterwards would rescale what was just set.
    added.HiDPI  = request.hiDPI;
    added.width  = width;
    added.height = height;
    [resolutions addObject: added];

    char detail[128];
    snprintf(detail, sizeof(detail), "Added %ux%u %s", width, height,
             request.hiDPI ? "HiDPI" : "standard");

    return SaveCustomResolutions(store, resolutions, detail);
}


static int RemoveCustomResolution(CGDirectDisplayID display, int index,
                                  const EZCommandRequest &request)
{
    CustomResolutionsStore *store = StoreFor(display, index);

    const uint32_t width  = (uint32_t) request.width;
    const uint32_t height = (uint32_t) request.height;

    NSMutableArray<Resolution *> *kept = [NSMutableArray array];
    NSUInteger removed = 0;

    for (Resolution *resolution in [store load]) {
        // Size alone, HiDPI or not: a display can carry both at one size, and
        // asking for that size back means neither of them.
        if (resolution.width == width && resolution.height == height)
            removed++;
        else
            [kept addObject: resolution];
    }

    if (removed == 0) {
        fprintf(stderr, "%ux%u is not a custom resolution for this display. "
                        "Try: ezdisplay custom list\n", width, height);
        return EZExitFailed;
    }

    char detail[128];
    snprintf(detail, sizeof(detail), "Removed %ux%u", width, height);

    return SaveCustomResolutions(store, kept, detail);
}


#pragma mark - Preferences

/// What one flag preference currently holds.
///
/// Named rather than keyed, because these are not all reads of the same store:
/// the first two come from the app's defaults through `EZPrefs`, so the
/// registered fallbacks apply, and the login item is held by the system.
static bool PreferenceFlag(const EZPreferenceInfo &preference)
{
    if (preference.name == "show-standard")
        return [EZPrefs resolvedShowStandard];
    if (preference.name == "show-refresh-menu")
        return [EZPrefs resolvedShowRefreshMenu];

    return [EZPrefs resolvedLaunchAtLogin];
}


static int ShowPreferences(const EZCommandRequest &request)
{
    std::vector<std::string> objects;

    for (const EZPreferenceInfo &preference : EZPreferences()) {
        const bool count = preference.type == EZPreferenceCount;
        const long value = count ? [EZPrefs resolvedCuratedCount] : PreferenceFlag(preference);

        if (!request.json) {
            char shown[16];
            if (count)
                snprintf(shown, sizeof(shown), "%ld", value);
            else
                snprintf(shown, sizeof(shown), "%s", value ? "on" : "off");

            fprintf(stdout, "%-18s %-4s  %s\n",
                    preference.name.c_str(), shown, preference.summary.c_str());
            continue;
        }

        EZJSONObject object;
        object.addString("name", preference.name);
        if (count)
            object.addInt("value", value);
        else
            object.addBool("value", value);
        object.addString("summary", preference.summary);
        objects.push_back(object.text());
    }

    if (request.json)
        fprintf(stdout, "%s\n", EZJSONArray(objects).c_str());

    return EZExitKept;
}


static int SetPreference(const EZCommandRequest &request)
{
    // Never null: the parser resolved the name against the same table and
    // refused the command outright when nothing matched.
    const EZPreferenceInfo *preference = EZFindPreference(request.prefName);

    switch (preference->type) {
        case EZPreferenceCount:
            [EZPrefs setResolvedCuratedCount: request.prefCount];
            fprintf(stdout, "%s is now %d.\n", preference->name.c_str(), request.prefCount);
            return EZExitKept;

        case EZPreferenceFlag:
            if (preference->name == "show-standard")
                [EZPrefs setResolvedShowStandard: request.prefFlag];
            else
                [EZPrefs setResolvedShowRefreshMenu: request.prefFlag];
            break;

        case EZPreferenceLoginItem: {
            NSString *failure = [EZPrefs setLaunchAtLogin: request.prefFlag];
            if (failure != nil) {
                fprintf(stderr, "Could not change the login item: %s\n", failure.UTF8String);
                return EZExitFailed;
            }
            break;
        }
    }

    fprintf(stdout, "%s is now %s.\n", preference->name.c_str(),
            request.prefFlag ? "on" : "off");
    return EZExitKept;
}


#pragma mark - Dispatch

int RunCommandLine(int argc, char *const *argv)
{
    // The same fallbacks the app registers on launch. Without them this process
    // reads an unset preference as zero and reports a curated count of 1 where
    // the menu shows 6 — the same defaults database, answering differently
    // because only one of the two readers had been told what the defaults are.
    [EZPrefs registerDefaults];

    EZCommandRequest request;
    std::string error;

    if (!EZParseCommandLine(argc, argv, &request, &error)) {
        fprintf(stderr, "ezdisplay: %s\n\n%s", error.c_str(), EZUsageText("").c_str());
        return EZExitFailed;
    }

    if (request.kind == EZCommandHelp) {
        fprintf(stdout, "%s", EZUsageText(request.helpTopic).c_str());
        return EZExitKept;
    }

    if (request.kind == EZCommandVersion) {
        fprintf(stdout, "%s", VersionText().c_str());
        return EZExitKept;
    }

    // The commands that have to work with nothing plugged in, so they run
    // before the display list is read: `uninstall` calls the first whatever is
    // attached at the time, and none of the others is about a display at all.
    if (request.kind == EZCommandRestore && request.everyDisplay)
        return RestoreEveryOverride();
    if (request.kind == EZCommandPrefs)
        return request.prefName.empty() ? ShowPreferences(request) : SetPreference(request);
    if (request.kind == EZCommandNightShift)
        return request.toggleAction == EZToggleActionShow
             ? ShowNightShift(request) : SetNightShift(request);
    if (request.kind == EZCommandTrueTone)
        return request.toggleAction == EZToggleActionShow
             ? ShowTrueTone(request) : SetTrueTone(request);

    std::vector<CGDirectDisplayID> displays = AttachedDisplays();

    // The two commands that are about the whole set rather than one of it.
    // Resolving a display first would fail both on a machine with none
    // attached — a headless Mac over SSH — and `list` would answer "no such
    // display" to a question that never named one.
    if (request.kind == EZCommandList)
        return ListDisplays(displays, request);
    if (request.kind == EZCommandMirror)
        return SetMirroring(request);

    int found = EZResolveDisplay(Identities(displays), request.display);

    if (found == EZDisplayAmbiguous) {
        fprintf(stderr, "More than one display reports that vendor and product. "
                        "Select one by index instead: ezdisplay list\n");
        return EZExitFailed;
    }
    if (found == EZDisplayNotFound) {
        fprintf(stderr, "No such display. Try: ezdisplay list\n");
        return EZExitFailed;
    }

    CGDirectDisplayID display = displays[found];

    switch (request.kind) {
        case EZCommandModes:   return ListModes(display, request);
        case EZCommandSet:     return SetMode(display, request);
        case EZCommandHDR:     return SetHDR(display, request);
        case EZCommandRestore: return RestoreOneOverride(display, found);

        case EZCommandColor:
            return request.colorAction == EZColorActionList
                 ? ListColorModes(display, request)
                 : SetColorMode(display, request);

        case EZCommandBrightness:
            return request.toggleAction == EZToggleActionShow
                 ? ShowBrightness(display, request)
                 : SetBrightnessPercent(display, request);

        case EZCommandVolume:
            return request.toggleAction == EZToggleActionShow
                 ? ShowVolume(display, request)
                 : SetVolumePercent(display, request);

        case EZCommandMute:
            return request.toggleAction == EZToggleActionShow
                 ? ShowMute(display, request)
                 : SetMute(display, request);

        case EZCommandCustom:
            switch (request.customAction) {
                case EZCustomActionList:   return ListCustomResolutions(display, found, request);
                case EZCustomActionAdd:    return AddCustomResolution(display, found, request);
                case EZCustomActionRemove: return RemoveCustomResolution(display, found, request);
            }
            break;

        case EZCommandHelp:
        case EZCommandVersion:
        case EZCommandList:
        case EZCommandMirror:
        case EZCommandPrefs:
        case EZCommandNightShift:
        case EZCommandTrueTone:
            break;  // handled above
    }

    return EZExitFailed;
}
