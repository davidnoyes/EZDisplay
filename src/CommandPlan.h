//
//  CommandPlan.h
//  EZDisplay
//
//  The decisions the command line makes before it touches a display: what the
//  arguments asked for, which display they meant, and which mode satisfies
//  them.
//
//  Everything here is a pure function over plain values, deliberately. The
//  executor in cmdline.mm reads the display list and the mode list through the
//  private services and writes the results back out, none of which a test can
//  exercise; the choices it makes with what it read are all in this file, where
//  they can be.
//

#pragma once

#include <stdint.h>

#include <string>
#include <vector>

/// What the process exits with. A change that was applied and kept is the only
/// success: a reverted change left the display where it started, which a script
/// has to be able to tell apart from having got what it asked for.
enum EZExitCode {
    EZExitKept     = 0,
    EZExitFailed   = 1,
    EZExitReverted = 2,
};

enum EZCommandKind {
    EZCommandHelp,
    EZCommandList,
    EZCommandModes,
    EZCommandSet,
    EZCommandHDR,
    EZCommandMirror,
    EZCommandColor,
    EZCommandRestore,
    EZCommandCustom,
    EZCommandPrefs,
    EZCommandNightShift,
    EZCommandTrueTone,
};

/// Which display a command applies to.
///
/// An index is positional and does not survive a reconnect, so a display can
/// also be named by the vendor and product pair the interface keys on. Neither
/// separates two monitors of the same model, which is why resolving a pair that
/// matches more than one display fails rather than picking one.
struct EZDisplaySelector {
    bool     given   = false;   // false: the main display
    bool     byIndex = false;
    int      index   = 0;
    uint32_t vendor  = 0;
    uint32_t product = 0;
};

enum EZColorAction {
    EZColorActionList,
    EZColorActionSet,
};

enum EZCustomAction {
    EZCustomActionList,
    EZCustomActionAdd,
    EZCustomActionRemove,
};

/// What a `nightshift` or `truetone` command was asked to do.
///
/// Reporting the state is an action here rather than a command of its own,
/// because `nightshift` and `nightshift on` are the same subject asked two
/// different things. `hdr` and `mirror` have no equivalent: they predate this
/// and always take a word, so they are left as they are rather than grown a
/// bare form nobody has asked for.
enum EZToggleAction {
    EZToggleActionShow,
    EZToggleActionSet,
    EZToggleActionWarmth,     // `nightshift` only
    EZToggleActionScheduled,  // `nightshift` only: hand the tint back to the schedule
    EZToggleActionSchedule,   // `nightshift` only: say what the schedule is
};

/// Which kind of schedule Night Shift runs on, matching the **Schedule** popup
/// in System Settings.
///
/// There is no third value for "no schedule". Off is not a kind of schedule but
/// a state of Night Shift, and it is reached the same way the menu reaches it:
/// `nightshift off`.
enum EZScheduleKind {
    EZScheduleSunset,   // sunset to sunrise, which needs location services
    EZScheduleCustom,   // a window the user picked
};

/// Night Shift's warmth as CoreBrightness holds it — 0 to 1 — from the whole
/// percentage the command line and the Preferences slider both deal in.
///
/// A percentage outside the range is clamped rather than refused, because both
/// callers have already refused what a user could type wrong: the parser rejects
/// anything that is not 0 to 100, and a slider cannot leave its own track. The
/// clamp is here so a future third caller cannot hand the private API a strength
/// it never promised to accept.
float EZWarmthFromPercent(int percent);

/// The same value back, as the whole percentage a listing prints. Rounded to
/// nearest, so the number shown for a warmth set from the same scale is the
/// number that was asked for.
int EZPercentFromWarmth(float warmth);

/// Minutes past midnight from a `HH:MM`, or -1 when `text` is not one.
///
/// The hour may be written with one digit or two, because `9:00` is how a
/// person writes nine o'clock. The minute must have both: `9:5` is as likely to
/// be a slip for `9:50` as for `9:05`, and there is no reading of it that is
/// safe to guess.
int EZParseTimeOfDay(const std::string &text);

/// A `HH:MM-HH:MM` window, into the two minute counts it names.
///
/// A window that runs backwards is the ordinary case rather than an error —
/// 22:00 to 07:00 is the one macOS ships with — so the only window refused is
/// one that starts and ends on the same minute, which has no length to run for.
bool EZParseScheduleWindow(const std::string &text, int *fromMinute, int *toMinute);

/// How a preference's value is written on the command line, which is also how
/// the executor has to store it.
enum EZPreferenceType {
    EZPreferenceFlag,       // on or off, in the app's own defaults
    EZPreferenceCount,      // a whole number, at least 1
    EZPreferenceLoginItem,  // on or off, but held by the system, not by defaults
};

/// One preference the command line can read and write.
///
/// `name` is the command-line spelling and `key` the defaults key behind it.
/// The two differ on purpose: the key is an implementation detail the interface
/// already chose, and a hyphenated name is what a shell user expects to type.
struct EZPreferenceInfo {
    std::string      name;
    std::string      key;
    EZPreferenceType type;
    std::string      summary;
};

/// Every preference, in the order `prefs` should print them.
const std::vector<EZPreferenceInfo> &EZPreferences();

/// The preference `name` refers to, or null when nothing does.
const EZPreferenceInfo *EZFindPreference(const std::string &name);

/// A truth value written the way a shell user writes one. Accepts `on`, `off`,
/// `true`, `false`, `yes`, `no`, `1`, and `0` in any case, and refuses anything
/// else rather than guessing — `prefs set show-standard maybe` is a typo, and
/// silently reading it as false would turn a preference off without saying so.
bool EZParseBool(const std::string &text, bool *value);

/// `text` as a JSON string, surrounding quotes included. Escapes what JSON
/// requires and emits every other control character as `\uXXXX`, so a display
/// name carrying one cannot produce output that will not parse.
std::string EZJSONString(const std::string &text);

/// One JSON object, built a field at a time in the order the fields are added.
///
/// Every `--json` listing goes through this rather than through its own format
/// string, so a value that needs escaping cannot reach the output unescaped in
/// one command and escaped in the next.
class EZJSONObject {
public:
    void addString(const std::string &key, const std::string &value);
    void addInt(const std::string &key, long value);
    void addBool(const std::string &key, bool value);

    /// A number that may carry a fraction, printed without the trailing zeros a
    /// fixed-precision format leaves behind: a scale of 2 is `2`, not `2.000000`.
    void addNumber(const std::string &key, double value);

    std::string text() const;

private:
    std::string fields;

    void add(const std::string &key, const std::string &value);
};

/// The objects as a JSON array. Takes them already rendered, because the caller
/// builds each one from a different kind of thing.
std::string EZJSONArray(const std::vector<std::string> &objects);

/// What the arguments asked for. Zero means "not given" for every filter, which
/// for `set` also means "take it from the mode the display is running".
struct EZCommandRequest {
    EZCommandKind    kind = EZCommandHelp;
    EZDisplaySelector display;

    int    width     = 0;
    int    height    = 0;
    int    refreshHz = 0;
    double scale     = 0;

    bool force        = false;   // apply without asking
    bool everyDisplay = false;   // restore --all
    bool on           = false;   // hdr/mirror on|off
    bool json         = false;   // machine-readable listing
    bool hiDPI        = false;   // custom add --hidpi

    EZColorAction colorAction = EZColorActionList;
    int           elementID   = 0;

    EZCustomAction customAction = EZCustomActionList;

    EZToggleAction toggleAction  = EZToggleActionShow;
    int            warmthPercent = 0;

    EZScheduleKind scheduleKind     = EZScheduleSunset;
    int            scheduleFrom     = 0;   // minutes past midnight, custom only
    int            scheduleTo       = 0;

    std::string prefName;        // empty: show every preference
    bool        prefFlag  = false;
    int         prefCount = 0;

    std::string helpTopic;       // empty: the general usage text
};

/// Fills in `request` from the arguments, `argv[0]` included.
///
/// Returns false and writes a one-line reason into `error` when the arguments
/// do not describe a command that can be run. The reason names what was wrong
/// rather than printing the whole usage text, so the caller decides how much to
/// show.
bool EZParseCommandLine(int argc, const char *const *argv,
                        EZCommandRequest *request, std::string *error);

/// The usage text for one command, or for the tool when `topic` is empty. An
/// unrecognised topic gets the general text, because a reader who mistyped a
/// command name needs the list of real ones.
std::string EZUsageText(const std::string &topic);

/// A display, as far as choosing between them goes.
///
/// `isMain` is what a command with no `--display` acts on. The display list is
/// not documented to put that display first, so it is carried here rather than
/// assumed from the position.
struct EZDisplayIdentity {
    int      index   = 0;
    uint32_t vendor  = 0;
    uint32_t product = 0;
    bool     isMain  = false;
};

enum {
    EZDisplayNotFound  = -1,
    EZDisplayAmbiguous = -2,
};

/// Which entry of `displays` the selector means, as an offset into that array.
///
/// `EZDisplayNotFound` when nothing matches, and `EZDisplayAmbiguous` when a
/// vendor and product pair matches more than one — two identical monitors,
/// where acting on either would be a coin toss.
int EZResolveDisplay(const std::vector<EZDisplayIdentity> &displays,
                     const EZDisplaySelector &selector);

/// One entry of the private mode list. `number` is its position in that list,
/// which is what the apply call takes.
struct EZModeCandidate {
    int    number    = 0;
    int    width     = 0;
    int    height    = 0;
    int    refreshHz = 0;
    double scale     = 0;
};

/// Whether two entries describe the same mode: geometry, refresh rate, and
/// scale alike. Scale is part of it and easy to leave out — a display offering
/// 1920x1080 at both scales has two entries that differ in nothing else, so a
/// comparison without it calls them the same mode and marks both as current.
bool EZSameMode(const EZModeCandidate &a, const EZModeCandidate &b);

/// The same list with the duplicates the private service reports collapsed,
/// keeping the first of each geometry, scale, and rate. Measured on the test
/// machine: 1618 raw modes for one display, which is a listing nobody can read.
std::vector<EZModeCandidate> EZDedupeModes(const std::vector<EZModeCandidate> &modes);

/// Every mode that passes the filters the caller actually gave.
std::vector<EZModeCandidate> EZFilterModes(const std::vector<EZModeCandidate> &modes,
                                           const EZCommandRequest &request);

/// The `number` of the mode to switch to, or -1 when the request cannot be met.
///
/// Anything the request leaves out comes from `current`, so `--width` on its own
/// changes the width and keeps the rest. Refresh rate is the exception: asking
/// for one narrows the list and fails when no mode offers it, while leaving it
/// out prefers the rate in force and falls back to the highest the chosen
/// geometry supports. Carrying the current rate over as a filter would fail
/// every switch to a geometry that does not offer it, and taking whichever mode
/// the list yields first — what this used to do — lands on an arbitrary rate.
int EZChooseMode(const std::vector<EZModeCandidate> &modes,
                 const EZCommandRequest &request,
                 const EZModeCandidate &current);

/// Whether to put the confirm-or-revert question to the user at all.
///
/// A script has nobody to answer it, so a countdown there would revert every
/// automated change 20 seconds later — a silent failure worse than carrying no
/// safety net. `--force` says the caller has decided already.
bool EZShouldPrompt(bool force, bool interactive);

/// Whether an answer to that question keeps the change. Only an explicit yes
/// does: an empty line, an unrecognised word, and end of input (a null pointer)
/// all revert, because every reflex has to land on the outcome that can be
/// undone by waiting.
bool EZAnswerKeeps(const char *answer);
