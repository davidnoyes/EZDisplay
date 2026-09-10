//
//  CommandPlan.mm
//  EZDisplay
//
//  See CommandPlan.h. Nothing in this file reads or writes a display.
//

#import "CommandPlan.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <map>

namespace {

/// Scales are floats that came from a private structure, so they are compared
/// with a tolerance rather than for equality. The values in play are 1.0 and
/// 2.0, so anything this side of a hundredth is the same scale.
bool SameScale(double a, double b)
{
    return std::fabs(a - b) < 0.01;
}


bool CommandFromWord(const std::string &word, EZCommandKind *kind)
{
    static const std::map<std::string, EZCommandKind> commands = {
        {"list",    EZCommandList},
        {"modes",   EZCommandModes},
        {"set",     EZCommandSet},
        {"hdr",     EZCommandHDR},
        {"mirror",  EZCommandMirror},
        {"color",   EZCommandColor},
        {"restore", EZCommandRestore},
        {"custom",  EZCommandCustom},
        {"prefs",   EZCommandPrefs},
        {"nightshift", EZCommandNightShift},
        {"truetone",   EZCommandTrueTone},
        {"brightness", EZCommandBrightness},
        {"volume",     EZCommandVolume},
        {"mute",       EZCommandMute},
    };

    auto found = commands.find(word);
    if (found == commands.end())
        return false;

    *kind = found->second;
    return true;
}


/// Which options each command answers to. An option that belongs to another
/// command is refused rather than ignored: `mirror --display 1` asks for
/// something mirroring cannot do, and silently mirroring every display instead
/// is not what was asked for.
bool CommandAllowsOption(EZCommandKind kind, const std::string &name)
{
    if (name == "--display")
        return kind == EZCommandModes || kind == EZCommandSet
            || kind == EZCommandHDR   || kind == EZCommandColor
            || kind == EZCommandRestore || kind == EZCommandCustom
            || kind == EZCommandBrightness
            || kind == EZCommandVolume || kind == EZCommandMute;

    if (name == "--width" || name == "--height")
        return kind == EZCommandModes || kind == EZCommandSet || kind == EZCommandCustom;

    if (name == "--scale" || name == "--hz")
        return kind == EZCommandModes || kind == EZCommandSet;

    if (name == "--force")
        return kind == EZCommandSet || kind == EZCommandHDR
            || kind == EZCommandMirror || kind == EZCommandColor;

    if (name == "--all")
        return kind == EZCommandRestore;

    if (name == "--hidpi")
        return kind == EZCommandCustom;

    // Only where there is a listing to render. On a command that changes
    // something it would promise structured output that never comes.
    if (name == "--json")
        return kind == EZCommandList  || kind == EZCommandModes
            || kind == EZCommandColor || kind == EZCommandCustom
            || kind == EZCommandPrefs || kind == EZCommandNightShift
            || kind == EZCommandTrueTone || kind == EZCommandBrightness
            || kind == EZCommandVolume || kind == EZCommandMute;

    return false;
}


/// The long spelling of an option, so the rest of the parser and every error
/// message deals in one name. An unrecognised spelling comes back as itself,
/// which is what the "unknown option" message needs to print.
std::string LongName(const std::string &option)
{
    static const std::map<std::string, std::string> shortForms = {
        {"-d", "--display"},
        {"-w", "--width"},
        {"-s", "--scale"},
        {"-z", "--hz"},
        {"-f", "--force"},
        {"-h", "--help"},
        {"-v", "--version"},
    };

    auto found = shortForms.find(option);
    return found == shortForms.end() ? option : found->second;
}


/// A whole number that fits in an `int`.
///
/// The range check is not pedantry: every field this fills is an `int`, and
/// zero in one of them means "not given". A value that overflowed and truncated
/// to zero would read as a filter the caller never asked for.
bool ParseWholeNumber(const std::string &text, long *value)
{
    if (text.empty())
        return false;

    for (char c : text)
        if (!isdigit((unsigned char) c))
            return false;

    errno = 0;
    long parsed = strtol(text.c_str(), NULL, 10);
    if (errno == ERANGE || parsed > INT_MAX)
        return false;

    *value = parsed;
    return true;
}


/// A vendor or product identifier, written the way the display override files
/// spell it: hexadecimal, with the `0x` prefix optional because a user copies
/// what the listing showed them.
bool ParseIdentifier(const std::string &text, uint32_t *value)
{
    std::string digits = text;
    if (digits.rfind("0x", 0) == 0 || digits.rfind("0X", 0) == 0)
        digits = digits.substr(2);

    if (digits.empty())
        return false;

    for (char c : digits)
        if (!isxdigit((unsigned char) c))
            return false;

    errno = 0;
    unsigned long parsed = strtoul(digits.c_str(), NULL, 16);
    if (errno == ERANGE || parsed > UINT32_MAX)
        return false;

    *value = (uint32_t) parsed;
    return true;
}


bool ParseDisplaySelector(const std::string &text, EZDisplaySelector *selector)
{
    selector->given = true;

    size_t colon = text.find(':');
    if (colon == std::string::npos) {
        long index = 0;
        if (!ParseWholeNumber(text, &index))
            return false;

        selector->byIndex = true;
        selector->index = (int) index;
        return true;
    }

    return ParseIdentifier(text.substr(0, colon), &selector->vendor)
        && ParseIdentifier(text.substr(colon + 1), &selector->product);
}

}  // namespace


const std::vector<EZPreferenceInfo> &EZPreferences()
{
    // The defaults keys are the ones EZPrefs already registered, so the two
    // front ends read and write the same values rather than two sets that
    // happen to agree.
    static const std::vector<EZPreferenceInfo> preferences = {
        {"show-standard",    "EZShowStandard",    EZPreferenceFlag,
         "Show standard (non-HiDPI) resolutions in the menu"},
        {"show-refresh-menu", "EZShowRefreshMenu", EZPreferenceFlag,
         "Show the Refresh Rate submenu"},
        {"curated-count",    "EZCuratedCount",    EZPreferenceCount,
         "How many resolutions the menu lists before More Resolutions"},
        {"launch-at-login",  "EZLaunchAtLogin",   EZPreferenceLoginItem,
         "Start EZDisplay when you log in"},
    };

    return preferences;
}


const EZPreferenceInfo *EZFindPreference(const std::string &name)
{
    for (const EZPreferenceInfo &preference : EZPreferences())
        if (preference.name == name)
            return &preference;

    return NULL;
}


bool EZParseBool(const std::string &text, bool *value)
{
    std::string word;
    for (char c : text)
        word += (char) tolower((unsigned char) c);

    if (word == "on" || word == "true" || word == "yes" || word == "1") {
        *value = true;
        return true;
    }

    if (word == "off" || word == "false" || word == "no" || word == "0") {
        *value = false;
        return true;
    }

    return false;
}


std::string EZJSONString(const std::string &text)
{
    static const char *hex = "0123456789abcdef";

    std::string out = "\"";
    for (unsigned char c : text) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    out += "\\u00";
                    out += hex[c >> 4];
                    out += hex[c & 0xF];
                } else {
                    out += (char) c;
                }
        }
    }

    return out + "\"";
}


void EZJSONObject::add(const std::string &key, const std::string &value)
{
    if (!fields.empty())
        fields += ",";

    fields += EZJSONString(key) + ":" + value;
}


void EZJSONObject::addString(const std::string &key, const std::string &value)
{
    add(key, EZJSONString(value));
}


void EZJSONObject::addInt(const std::string &key, long value)
{
    char digits[32];
    snprintf(digits, sizeof(digits), "%ld", value);
    add(key, digits);
}


void EZJSONObject::addBool(const std::string &key, bool value)
{
    add(key, value ? "true" : "false");
}


void EZJSONObject::addNumber(const std::string &key, double value)
{
    // %g drops the trailing zeros and falls back to an exponent only for
    // magnitudes nothing here produces.
    char digits[32];
    snprintf(digits, sizeof(digits), "%g", value);
    add(key, digits);
}


std::string EZJSONObject::text() const
{
    return "{" + fields + "}";
}


std::string EZJSONArray(const std::vector<std::string> &objects)
{
    std::string out = "[";
    for (size_t i = 0; i < objects.size(); i++) {
        if (i > 0)
            out += ",";
        out += objects[i];
    }

    return out + "]";
}


bool EZParseCommandLine(int argc, const char *const *argv,
                        EZCommandRequest *request, std::string *error)
{
    *request = EZCommandRequest();
    error->clear();

    auto fail = [error](const std::string &message) {
        *error = message;
        return false;
    };

    if (argc < 2)
        return fail("no command given");

    const std::string command = argv[1];
    if (command == "help" || command == "--help" || command == "-h") {
        if (argc > 3)
            return fail("help explains one command at a time");

        request->kind = EZCommandHelp;
        if (argc > 2)
            request->helpTopic = argv[2];
        return true;
    }

    // Answered here rather than through `CommandFromWord`, for the same reason
    // help is: the three spellings are not all command words, and the answer
    // does not depend on a display, an option, or anything else the loop below
    // reads. It qualifies nothing, so a word after it was a mistake.
    if (command == "version" || command == "--version" || command == "-v") {
        if (argc > 2)
            return fail("version takes no arguments");

        request->kind = EZCommandVersion;
        return true;
    }

    if (!CommandFromWord(command, &request->kind))
        return fail("unknown command \"" + command + "\"");

    std::vector<std::string> positionals;

    for (int i = 2; i < argc; i++) {
        std::string token = argv[i];

        if (token.empty() || token[0] != '-') {
            positionals.push_back(token);
            continue;
        }

        // An option carries its value either attached with `=` or as the token
        // after it. Splitting here keeps the two spellings from being two cases
        // everywhere below.
        std::string name = token;
        std::string value;
        bool hasValue = false;

        size_t equals = token.find('=');
        if (equals != std::string::npos) {
            name = token.substr(0, equals);
            value = token.substr(equals + 1);
            hasValue = true;
        }

        name = LongName(name);

        if (name == "--help") {
            request->kind = EZCommandHelp;
            request->helpTopic = command;
            return true;
        }

        // Answered after any command for the same reason --help is: the usage
        // text offers both as common options, and one that only worked as the
        // first word would make that half untrue.
        if (name == "--version") {
            request->kind = EZCommandVersion;
            return true;
        }

        if (!CommandAllowsOption(request->kind, name))
            return fail("unknown option " + name + " for " + command);

        const bool wantsValue = (name != "--force" && name != "--all"
                                 && name != "--hidpi" && name != "--json");
        if (!wantsValue && hasValue)
            return fail(name + " takes no value");

        if (wantsValue && !hasValue) {
            // No value this tool takes begins with a dash, so the next token
            // being another option means this one was left without one. Taking
            // it anyway would report the wrong option as the bad value.
            if (i + 1 >= argc || argv[i + 1][0] == '-')
                return fail(name + " needs a value");
            value = argv[++i];
        }

        if (name == "--force") {
            request->force = true;
        } else if (name == "--all") {
            request->everyDisplay = true;
        } else if (name == "--hidpi") {
            request->hiDPI = true;
        } else if (name == "--json") {
            request->json = true;
        } else if (name == "--display") {
            if (!ParseDisplaySelector(value, &request->display))
                return fail("\"" + value + "\" is not a display index or a vendor:product pair");
        } else if (name == "--scale") {
            char *end = NULL;
            double scale = strtod(value.c_str(), &end);
            if (end == value.c_str() || *end != '\0' || scale <= 0)
                return fail("\"" + value + "\" is not a scale");
            request->scale = scale;
        } else {
            long number = 0;
            if (!ParseWholeNumber(value, &number) || number <= 0)
                return fail("\"" + value + "\" is not a " +
                            (name == "--hz" ? "refresh rate" : "size in pixels"));

            if (name == "--width")       request->width = (int) number;
            else if (name == "--height") request->height = (int) number;
            else                         request->refreshHz = (int) number;
        }
    }

    switch (request->kind) {
        case EZCommandHDR:
        case EZCommandMirror: {
            if (positionals.size() != 1)
                return fail(command + " takes on or off");
            if (positionals[0] == "on")       request->on = true;
            else if (positionals[0] == "off") request->on = false;
            else return fail(command + " takes on or off, not \"" + positionals[0] + "\"");
            break;
        }

        case EZCommandColor: {
            if (positionals.empty() || positionals[0] == "list") {
                if (positionals.size() > 1)
                    return fail("color list takes nothing else");
                request->colorAction = EZColorActionList;
                break;
            }
            if (positionals[0] != "set")
                return fail("color takes list or set, not \"" + positionals[0] + "\"");
            if (positionals.size() != 2)
                return fail("color set takes the mode's element ID, as color list prints it");
            // The flag is allowed on `color` because `color list` renders one.
            // Which action was asked for is only known here.
            if (request->json)
                return fail("color set takes no --json: it changes the mode rather than "
                            "printing one");

            long element = 0;
            if (!ParseWholeNumber(positionals[1], &element))
                return fail("\"" + positionals[1] + "\" is not an element ID");

            request->colorAction = EZColorActionSet;
            request->elementID = (int) element;
            break;
        }

        case EZCommandSet: {
            if (!positionals.empty())
                return fail("set takes options, not \"" + positionals[0] + "\"");
            if (!request->width && !request->height && !request->scale && !request->refreshHz)
                return fail("set needs at least one of --width, --height, --scale, or --hz");
            break;
        }

        case EZCommandCustom: {
            const std::string action = positionals.empty() ? "list" : positionals[0];

            if (action == "list") {
                if (positionals.size() > 1)
                    return fail("custom list takes nothing else");
                // Given a size, the listing would look like it filters on it.
                if (request->width || request->height || request->hiDPI)
                    return fail("custom list takes no resolution; did you mean custom add?");
                request->customAction = EZCustomActionList;
                break;
            }

            if (action != "add" && action != "remove")
                return fail("custom takes list, add, or remove, not \"" + action + "\"");
            if (positionals.size() != 1)
                return fail("custom " + action + " takes options, not \"" + positionals[1] + "\"");
            if (!request->width || !request->height)
                return fail("custom " + action + " needs --width and --height");
            // As with `color set`: the flag belongs to `custom list`, and only
            // the action tells the two apart.
            if (request->json)
                return fail("custom " + action + " takes no --json: it changes the list "
                            "rather than printing it");
            // Remove drops every custom entry of that size, so the flag would
            // narrow nothing. Taking it would say otherwise.
            if (action == "remove" && request->hiDPI)
                return fail("custom remove takes no --hidpi: it removes every custom "
                            "resolution of that size");

            request->customAction = action == "add" ? EZCustomActionAdd : EZCustomActionRemove;
            break;
        }

        case EZCommandPrefs: {
            if (positionals.empty())
                break;   // show them all

            if (positionals[0] != "set")
                return fail("prefs takes set, not \"" + positionals[0] + "\"");
            if (positionals.size() != 3)
                return fail("prefs set takes a preference and a value: "
                            "ezdisplay prefs set curated-count 8");

            const EZPreferenceInfo *preference = EZFindPreference(positionals[1]);
            if (preference == NULL)
                return fail("no preference is called \"" + positionals[1] +
                            "\". Try: ezdisplay prefs");

            const std::string &value = positionals[2];
            if (preference->type == EZPreferenceCount) {
                long count = 0;
                // Zero is refused rather than clamped the way the interface
                // clamps it on read: a caller who asked for it should hear that
                // it is not a choice, not find the value quietly changed.
                if (!ParseWholeNumber(value, &count) || count < 1)
                    return fail("\"" + value + "\" is not a count of at least 1");
                request->prefCount = (int) count;
            } else if (!EZParseBool(value, &request->prefFlag)) {
                return fail("\"" + value + "\" is not on or off");
            }

            request->prefName = preference->name;
            break;
        }

        case EZCommandNightShift:
        case EZCommandTrueTone:
        // Mute joins these rather than brightness because it has two states
        // rather than a scale. The error messages quote `command`, which is the
        // word that was typed, so they read correctly for all three.
        case EZCommandMute: {
            const bool warmthIsMine = request->kind == EZCommandNightShift;

            if (positionals.empty()) {
                request->toggleAction = EZToggleActionShow;
                break;
            }

            const std::string &action = positionals[0];

            if (action == "on" || action == "off") {
                if (positionals.size() != 1)
                    return fail(command + " " + action + " takes nothing else");
                // As with `color set`: the flag belongs to the bare form, which
                // reports the state, and only the action tells the two apart.
                if (request->json)
                    return fail(command + " " + action + " takes no --json: it changes "
                                "the setting rather than printing it");
                request->toggleAction = EZToggleActionSet;
                request->on = action == "on";
                break;
            }

            if (warmthIsMine && action == "warmth") {
                if (positionals.size() != 2)
                    return fail("nightshift warmth takes one whole percentage, 0 to 100");
                if (request->json)
                    return fail("nightshift warmth takes no --json: it changes the "
                                "warmth rather than printing it");

                long percent = 0;
                // Clamping would take `warmth 700`, a plain typo for 70, and set
                // the warmest there is while reporting the success of a change
                // nobody asked for.
                if (!ParseWholeNumber(positionals[1], &percent) || percent > 100)
                    return fail("\"" + positionals[1] + "\" is not a warmth: a whole "
                                "percentage from 0 to 100");

                request->toggleAction = EZToggleActionWarmth;
                request->warmthPercent = (int) percent;
                break;
            }

            if (warmthIsMine && action == "scheduled") {
                if (positionals.size() != 1)
                    return fail("nightshift scheduled takes nothing else");
                if (request->json)
                    return fail("nightshift scheduled takes no --json: it changes "
                                "the setting rather than printing it");

                request->toggleAction = EZToggleActionScheduled;
                break;
            }

            if (warmthIsMine && action == "schedule") {
                // Both the wrong word count and the wrong word land on the same
                // description, because a reader who got either one wrong needs
                // to be told the same two forms.
                static const std::string forms =
                    "sunset, or a window written HH:MM-HH:MM";

                if (positionals.size() != 2)
                    return fail("nightshift schedule takes one schedule: " + forms);
                if (request->json)
                    return fail("nightshift schedule takes no --json: it changes "
                                "the schedule rather than printing it");

                if (positionals[1] == "sunset") {
                    request->scheduleKind = EZScheduleSunset;
                } else if (EZParseScheduleWindow(positionals[1], &request->scheduleFrom,
                                                 &request->scheduleTo)) {
                    request->scheduleKind = EZScheduleCustom;
                } else {
                    return fail("\"" + positionals[1] + "\" is not a schedule: " + forms);
                }

                request->toggleAction = EZToggleActionSchedule;
                break;
            }

            return fail(command + " takes on or off" +
                        (warmthIsMine ? ", scheduled, warmth and a percentage, "
                                        "or schedule and a window" : "") +
                        ", not \"" + action + "\"");
        }

        // One dial each, on the same scale, so they parse the same way.
        case EZCommandBrightness:
        case EZCommandVolume: {
            if (positionals.empty()) {
                request->toggleAction = EZToggleActionShow;
                break;
            }

            // No `set` word in front of the number: each has one thing to
            // change, so a word saying which would only ever have one value.
            if (positionals.size() != 1)
                return fail(command + " takes one whole percentage, 0 to 100");
            // As with `color set`: the flag belongs to the bare reporting form,
            // and only the argument count tells the two apart.
            if (request->json)
                return fail(command + " <percentage> takes no --json: it changes "
                            "the " + command + " rather than printing it");

            long percent = 0;
            // Refused rather than clamped, for the reason `nightshift warmth`
            // gives: `brightness 700` is a typo for 70, and clamping it would
            // report success for full brightness nobody asked for.
            if (!ParseWholeNumber(positionals[0], &percent) || percent > 100)
                return fail("\"" + positionals[0] + "\" is not a " + command +
                            ": a whole percentage from 0 to 100");

            request->toggleAction = EZToggleActionSet;
            if (request->kind == EZCommandVolume)
                request->volumePercent = (int) percent;
            else
                request->brightnessPercent = (int) percent;
            break;
        }

        case EZCommandRestore: {
            if (!positionals.empty())
                return fail("restore takes options, not \"" + positionals[0] + "\"");
            if (!request->everyDisplay && !request->display.given)
                return fail("restore needs --display or --all");
            // Refused rather than resolved in --all's favour: the two ask for
            // different things, and guessing wrong here removes overrides for
            // displays the caller named one of.
            if (request->everyDisplay && request->display.given)
                return fail("restore takes --display or --all, not both");
            break;
        }

        default: {
            if (!positionals.empty())
                return fail(command + " takes no arguments, so \"" + positionals[0] +
                            "\" is not one it understands");
            break;
        }
    }

    return true;
}


float EZFractionFromPercent(int percent)
{
    if (percent <= 0)   return 0.0f;
    if (percent >= 100) return 1.0f;
    return (float) percent / 100.0f;
}


int EZPercentFromFraction(float fraction)
{
    if (fraction <= 0.0f) return 0;
    if (fraction >= 1.0f) return 100;
    // Rounded rather than truncated, so a value set from this same scale reads
    // back as the number that was asked for: 0.07f * 100 is 6.999999 in float,
    // and truncating it reports 6% for a value of 7%.
    return (int) lroundf(fraction * 100.0f);
}


int EZParseTimeOfDay(const std::string &text)
{
    size_t colon = text.find(':');
    if (colon == std::string::npos || text.find(':', colon + 1) != std::string::npos)
        return -1;

    const std::string hourText   = text.substr(0, colon);
    const std::string minuteText = text.substr(colon + 1);

    // The two halves are held to different widths on purpose: see the header.
    // ParseWholeNumber does the rest, and it is the reason a sign is refused —
    // it takes digits only, so `+9:00` never reaches the range check.
    if (hourText.empty() || hourText.size() > 2 || minuteText.size() != 2)
        return -1;

    long hour = 0, minute = 0;
    if (!ParseWholeNumber(hourText, &hour) || !ParseWholeNumber(minuteText, &minute))
        return -1;

    if (hour > 23 || minute > 59)
        return -1;

    return (int) (hour * 60 + minute);
}


bool EZParseScheduleWindow(const std::string &text, int *fromMinute, int *toMinute)
{
    size_t dash = text.find('-');
    if (dash == std::string::npos)
        return false;

    // Split at the first dash and let the time parser judge both halves. A
    // second dash therefore fails as part of a time rather than needing a count
    // of its own: `22:00-07:00-09:00` leaves `07:00-09:00`, which is not one.
    int from = EZParseTimeOfDay(text.substr(0, dash));
    int to   = EZParseTimeOfDay(text.substr(dash + 1));
    if (from < 0 || to < 0 || from == to)
        return false;

    *fromMinute = from;
    *toMinute   = to;
    return true;
}


std::string EZUsageText(const std::string &topic)
{
    static const std::map<std::string, std::string> perCommand = {
        {"list",
         "Usage: ezdisplay list\n"
         "\n"
         "Lists the attached displays: the index and the vendor:product pair either\n"
         "of which selects one, the mode it is running, and whether HDR is on.\n"},

        {"modes",
         "Usage: ezdisplay modes [--display <selector>] [filters]\n"
         "\n"
         "Lists the modes a display supports. The filters narrow the listing and are\n"
         "the same ones set takes: --width, --height, --scale, --hz.\n"},

        {"set",
         "Usage: ezdisplay set [--width <px>] [--height <px>] [--scale <n>] [--hz <n>]\n"
         "                     [--display <selector>] [--force]\n"
         "\n"
         "Changes resolution, scale, or refresh rate. Anything left out comes from the\n"
         "mode the display is running, so --width on its own changes the width and\n"
         "keeps the rest.\n"
         "\n"
         "  --width  <px>   Width. Short form -w; height has no short form, because -h\n"
         "                  is help.\n"
         "  --height <px>   Height\n"
         "  --scale  <n>    Scale, where 2.0 is HiDPI. Short form -s\n"
         "  --hz     <n>    Refresh rate. Short form -z. Left out, the rate in force is\n"
         "                  kept where the new geometry offers it, and the highest it\n"
         "                  does offer is taken where it does not\n"},

        {"hdr",
         "Usage: ezdisplay hdr on|off [--display <selector>] [--force]\n"
         "\n"
         "Turns high dynamic range on or off for one display.\n"},

        {"mirror",
         "Usage: ezdisplay mirror on|off [--force]\n"
         "\n"
         "Turns mirroring on or off for the whole set of displays, which is why this\n"
         "command takes no display selector.\n"},

        {"nightshift",
         "Usage: ezdisplay nightshift [--json]\n"
         "       ezdisplay nightshift on|off|scheduled\n"
         "       ezdisplay nightshift warmth <0-100>\n"
         "       ezdisplay nightshift schedule sunset|<HH:MM-HH:MM>\n"
         "\n"
         "Shows how Night Shift is set, or changes it. Night Shift is one setting for\n"
         "the whole machine, so this command takes no display selector.\n"
         "\n"
         "  on          Turn the tint on until tomorrow, which is what the checkbox in\n"
         "              System Settings does. macOS clears it at the next schedule\n"
         "              boundary\n"
         "  off         Turn the tint off, and take the schedule off with it\n"
         "  scheduled   Hand the tint back to the schedule, so it comes and goes on its\n"
         "              own again\n"
         "  warmth      How warm the tint is, 0 to 100, which is separate from whether\n"
         "              it is on\n"
         "  schedule    Which schedule `scheduled` runs. sunset needs location services;\n"
         "              a window is written 22:00-07:00 and may run past midnight\n"},

        {"truetone",
         "Usage: ezdisplay truetone [--json]\n"
         "       ezdisplay truetone on|off\n"
         "\n"
         "Shows whether True Tone is on, or turns it on or off. True Tone is one\n"
         "setting for the whole machine, so this command takes no display selector,\n"
         "and a display that does not support it is reported rather than changed.\n"},

        {"brightness",
         "Usage: ezdisplay brightness [--display <selector>] [--json]\n"
         "       ezdisplay brightness <0-100> [--display <selector>]\n"
         "\n"
         "Shows one display's brightness as a percentage, or sets it. Unlike Night\n"
         "Shift and True Tone this belongs to a display rather than to the machine, so\n"
         "it takes a selector.\n"
         "\n"
         "This is the same dial the brightness keys move, not the monitor's own menu.\n"
         "A display macOS cannot dim is reported rather than changed.\n"},

        {"volume",
         "Usage: ezdisplay volume [--display <selector>] [--json]\n"
         "       ezdisplay volume <0-100> [--display <selector>]\n"
         "\n"
         "Shows a monitor's own speaker volume as a percentage, or sets it. This is\n"
         "the monitor's dial, reached over DDC, and not the Mac's output volume: the\n"
         "two are separate, and turning one down leaves the other where it was.\n"
         "\n"
         "Only a display that reports the standard volume code can be set, and every\n"
         "change is read back, so a monitor that ignores the write is reported rather\n"
         "than claimed as changed. A monitor with no speakers is reported too.\n"},

        {"mute",
         "Usage: ezdisplay mute [--display <selector>] [--json]\n"
         "       ezdisplay mute on|off [--display <selector>]\n"
         "\n"
         "Shows whether a monitor's own speakers are muted, or mutes them. Like\n"
         "volume this is the monitor's control over DDC rather than the Mac's, and it\n"
         "is a separate code: a monitor can offer one of the two and not the other.\n"},

        {"color",
         "Usage: ezdisplay color list [--display <selector>] [--json]\n"
         "       ezdisplay color set <element ID> [--display <selector>] [--force]\n"
         "\n"
         "Lists the colour modes valid at the display's current timing, or applies one\n"
         "by the element ID the listing prints. A colour mode lasts until the timing\n"
         "changes, the display is disconnected, or the machine restarts.\n"},

        {"restore",
         "Usage: ezdisplay restore --display <selector>\n"
         "       ezdisplay restore --all\n"
         "\n"
         "Removes the display override files EZDisplay created, which is what undoes a\n"
         "custom resolution. --all covers every display it has touched, including ones\n"
         "that are not plugged in. Override files another tool created are left alone\n"
         "and reported. Needs an administrator password.\n"},

        {"custom",
         "Usage: ezdisplay custom list [--display <selector>] [--json]\n"
         "       ezdisplay custom add --width <px> --height <px> [--hidpi]\n"
         "                            [--display <selector>]\n"
         "       ezdisplay custom remove --width <px> --height <px>\n"
         "                               [--display <selector>]\n"
         "\n"
         "Adds a resolution the display does not advertise, or removes one added\n"
         "earlier. A custom resolution is written into the display's override file, so\n"
         "adding or removing one needs an administrator password and takes effect once\n"
         "the display reconnects or the machine restarts.\n"
         "\n"
         "  --width  <px>   Width, required by add and remove\n"
         "  --height <px>   Height, required by add and remove\n"
         "  --hidpi         Add it as a HiDPI mode, so it renders at twice the size\n"},

        {"prefs",
         "Usage: ezdisplay prefs [--json]\n"
         "       ezdisplay prefs set <preference> <value>\n"
         "\n"
         "Shows the settings the menu bar app keeps, or changes one. A running app\n"
         "reads the new value the next time it rebuilds its menu, so a change made here\n"
         "may not show up until the display set changes or the app is restarted.\n"
         "\n"
         "  show-standard       on|off   Show standard (non-HiDPI) resolutions\n"
         "  show-refresh-menu   on|off   Show the Refresh Rate submenu\n"
         "  curated-count       <n>      How many resolutions the menu lists before\n"
         "                               More Resolutions, at least 1\n"
         "  launch-at-login     on|off   Start EZDisplay when you log in\n"
         "\n"
         "A truth value can be written on, off, true, false, yes, no, 1, or 0.\n"},

        {"version",
         "Usage: ezdisplay version\n"
         "\n"
         "Prints the release this is and the build it was made from, as\n"
         "\"ezdisplay 1.2.3 (45)\". Also spelled --version and -v.\n"},
    };

    auto found = perCommand.find(topic);
    if (found != perCommand.end())
        return found->second;

    return
        "Usage: ezdisplay <command> [options]\n"
        "\n"
        "Commands:\n"
        "  list       List the attached displays\n"
        "  modes      List the modes a display supports\n"
        "  set        Change resolution, scale, or refresh rate\n"
        "  hdr        Turn HDR on or off\n"
        "  mirror     Turn display mirroring on or off\n"
        "  nightshift Show or change Night Shift: on, off, scheduled, warmth,\n"
        "             schedule\n"
        "  truetone   Show, or turn on or off, True Tone\n"
        "  brightness Show or set a display's brightness, 0 to 100\n"
        "  volume     Show or set a monitor's own speaker volume, 0 to 100\n"
        "  mute       Show, or turn on or off, a monitor's own mute\n"
        "  color      List or apply the display's colour modes\n"
        "  restore    Remove the display overrides EZDisplay created\n"
        "  custom     List, add, or remove a custom resolution\n"
        "  prefs      Show or change the app's settings\n"
        "  version    Print the release and build this is\n"
        "  help       Explain a command: ezdisplay help set\n"
        "\n"
        "Common options:\n"
        "  -d, --display <selector>   A display index, as list prints it, or a\n"
        "                             vendor:product pair (default: the main display)\n"
        "  -f, --force                Apply without asking for confirmation\n"
        "      --json                 Machine-readable output, where there is a\n"
        "                             listing to render\n"
        "  -h, --help                 This text, or a command's own\n"
        "  -v, --version              The release and build this is\n"
        "\n"
        "A change that can black out the screen is applied, then reverted after 20\n"
        "seconds unless you answer y. Piped or redirected, where nobody can answer,\n"
        "the change is applied and kept.\n"
        "\n"
        "Exit status: 0 the change was kept, 1 it failed, 2 it was reverted.\n";
}


std::string EZVersionText(const std::string &shortVersion, const std::string &build)
{
    if (build.empty())
        return "ezdisplay " + shortVersion + "\n";

    return "ezdisplay " + shortVersion + " (" + build + ")\n";
}


int EZResolveDisplay(const std::vector<EZDisplayIdentity> &displays,
                     const EZDisplaySelector &selector)
{
    if (displays.empty())
        return EZDisplayNotFound;

    if (!selector.given) {
        for (size_t i = 0; i < displays.size(); i++)
            if (displays[i].isMain)
                return (int) i;
        return 0;
    }

    if (selector.byIndex) {
        for (size_t i = 0; i < displays.size(); i++)
            if (displays[i].index == selector.index)
                return (int) i;
        return EZDisplayNotFound;
    }

    int match = EZDisplayNotFound;
    for (size_t i = 0; i < displays.size(); i++) {
        if (displays[i].vendor != selector.vendor || displays[i].product != selector.product)
            continue;
        if (match != EZDisplayNotFound)
            return EZDisplayAmbiguous;
        match = (int) i;
    }

    return match;
}


bool EZSameMode(const EZModeCandidate &a, const EZModeCandidate &b)
{
    return a.width == b.width && a.height == b.height
        && a.refreshHz == b.refreshHz && SameScale(a.scale, b.scale);
}


std::vector<EZModeCandidate> EZDedupeModes(const std::vector<EZModeCandidate> &modes)
{
    std::vector<EZModeCandidate> unique;

    for (const EZModeCandidate &mode : modes) {
        bool seen = false;
        for (const EZModeCandidate &kept : unique) {
            if (EZSameMode(kept, mode)) {
                seen = true;
                break;
            }
        }
        if (!seen)
            unique.push_back(mode);
    }

    return unique;
}


std::vector<EZModeCandidate> EZFilterModes(const std::vector<EZModeCandidate> &modes,
                                           const EZCommandRequest &request)
{
    std::vector<EZModeCandidate> kept;

    for (const EZModeCandidate &mode : modes) {
        if (request.width && mode.width != request.width)             continue;
        if (request.height && mode.height != request.height)          continue;
        if (request.refreshHz && mode.refreshHz != request.refreshHz) continue;
        if (request.scale && !SameScale(mode.scale, request.scale))   continue;
        kept.push_back(mode);
    }

    return kept;
}


int EZChooseMode(const std::vector<EZModeCandidate> &modes,
                 const EZCommandRequest &request,
                 const EZModeCandidate &current)
{
    EZCommandRequest geometry;
    geometry.width  = request.width  ? request.width  : current.width;
    geometry.height = request.height ? request.height : current.height;
    geometry.scale  = request.scale  ? request.scale  : current.scale;
    geometry.refreshHz = request.refreshHz;

    std::vector<EZModeCandidate> candidates = EZFilterModes(modes, geometry);
    if (candidates.empty())
        return -1;

    if (request.refreshHz)
        return candidates.front().number;

    for (const EZModeCandidate &candidate : candidates)
        if (candidate.refreshHz == current.refreshHz)
            return candidate.number;

    const EZModeCandidate *fastest = &candidates.front();
    for (const EZModeCandidate &candidate : candidates)
        if (candidate.refreshHz > fastest->refreshHz)
            fastest = &candidate;

    return fastest->number;
}


bool EZShouldPrompt(bool force, bool interactive)
{
    return interactive && !force;
}


bool EZAnswerKeeps(const char *answer)
{
    if (answer == NULL)
        return false;

    std::string text = answer;
    text.erase(0, text.find_first_not_of(" \t\r\n"));
    size_t end = text.find_last_not_of(" \t\r\n");
    text.erase(end == std::string::npos ? 0 : end + 1);

    for (char &c : text)
        c = (char) tolower((unsigned char) c);

    return text == "y" || text == "yes";
}
