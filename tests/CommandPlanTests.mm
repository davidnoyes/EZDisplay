//
//  CommandPlanTests.mm
//  EZDisplay
//
//  Tests for the decisions in src/CommandPlan.h: reading the arguments,
//  choosing the display, and choosing the mode.
//
//  These are the parts of the command line that used to be wrong in ways no
//  script could see. A mode change that matched nothing still exited zero; the
//  refresh rate was printed but never filtered on, so a display offering 60,
//  120, and 144 Hz at one geometry landed on whichever mode the private list
//  happened to yield first; and `-h` meant height, so there was no way to ask
//  for help. Each of those is a case below.
//

#import <XCTest/XCTest.h>
#import "CommandPlan.h"

#include <string>
#include <vector>

/// Parses a command line written the way a user would type it. `argv[0]` is
/// added here so the tests read as the command rather than as an array.
static bool ParseWords(const std::vector<std::string> &words,
                       EZCommandRequest *request, std::string *error)
{
    std::vector<const char *> argv;
    argv.push_back("ezdisplay");
    for (const std::string &word : words)
        argv.push_back(word.c_str());

    return EZParseCommandLine((int) argv.size(), argv.data(), request, error);
}

/// The parse succeeded, and the caller wants the request it produced.
static EZCommandRequest ParsedOK(const std::vector<std::string> &words)
{
    EZCommandRequest request;
    std::string error;
    XCTAssertTrue(ParseWords(words, &request, &error), @"%s", error.c_str());
    return request;
}

static bool ParseFails(const std::vector<std::string> &words, std::string *error)
{
    EZCommandRequest request;
    return !ParseWords(words, &request, error);
}


#pragma mark - Reading the arguments

@interface CommandParsingTests : XCTestCase
@end

@implementation CommandParsingTests

- (void)testNoArgumentsIsNotACommand
{
    std::string error;
    XCTAssertTrue(ParseFails({}, &error));
    XCTAssertFalse(error.empty());
}

- (void)testHelpIsAskedForInAllThreeUsualWays
{
    // The defect this closes: `-h` used to mean height, so the one flag every
    // Unix tool answers did nothing but print the usage as an error.
    XCTAssertEqual(ParsedOK({"help"}).kind, EZCommandHelp);
    XCTAssertEqual(ParsedOK({"--help"}).kind, EZCommandHelp);
    XCTAssertEqual(ParsedOK({"-h"}).kind, EZCommandHelp);
}

- (void)testHelpTakesACommandToExplain
{
    EZCommandRequest request = ParsedOK({"help", "set"});
    XCTAssertEqual(request.kind, EZCommandHelp);
    XCTAssertEqual(request.helpTopic, std::string("set"));
}

- (void)testACommandExplainsItselfWithHelp
{
    EZCommandRequest request = ParsedOK({"set", "--help"});
    XCTAssertEqual(request.kind, EZCommandHelp);
    XCTAssertEqual(request.helpTopic, std::string("set"));
}

- (void)testTheVersionIsAskedForInAllThreeUsualWays
{
    // The same three spellings help answers to. A tool that can update itself
    // has to be able to say what it is now, and a release process that cannot
    // be checked from a script is one nobody checks.
    XCTAssertEqual(ParsedOK({"version"}).kind, EZCommandVersion);
    XCTAssertEqual(ParsedOK({"--version"}).kind, EZCommandVersion);
    XCTAssertEqual(ParsedOK({"-v"}).kind, EZCommandVersion);
}

- (void)testVersionTakesNoArguments
{
    // It answers one question and has nothing to qualify. Accepting a word and
    // ignoring it would read as though the word had meant something.
    std::string error;
    XCTAssertTrue(ParseFails({"version", "set"}, &error));
}

- (void)testAnUnknownCommandIsNamedInTheError
{
    std::string error;
    XCTAssertTrue(ParseFails({"contrast"}, &error));
    XCTAssertNotEqual(error.find("contrast"), std::string::npos);
}

- (void)testAnUnknownOptionIsNamedInTheError
{
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--bits", "32"}, &error));
    XCTAssertNotEqual(error.find("--bits"), std::string::npos);
}

- (void)testSetTakesGeometryScaleAndRate
{
    EZCommandRequest request = ParsedOK({"set", "--width", "3008", "--height", "1692",
                                         "--scale", "2.0", "--hz", "120"});
    XCTAssertEqual(request.kind, EZCommandSet);
    XCTAssertEqual(request.width, 3008);
    XCTAssertEqual(request.height, 1692);
    XCTAssertEqual(request.scale, 2.0);
    XCTAssertEqual(request.refreshHz, 120);
}

- (void)testSetTakesTheShortFormsAndAttachedValues
{
    EZCommandRequest request = ParsedOK({"set", "-w", "1920", "--height=1080", "-z", "60"});
    XCTAssertEqual(request.width, 1920);
    XCTAssertEqual(request.height, 1080);
    XCTAssertEqual(request.refreshHz, 60);
}

- (void)testSetWithNothingToChangeIsAnError
{
    std::string error;
    XCTAssertTrue(ParseFails({"set"}, &error));
    XCTAssertFalse(error.empty());
}

- (void)testAnOptionWithoutItsValueIsAnError
{
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--width"}, &error));
    XCTAssertNotEqual(error.find("--width"), std::string::npos);
}

- (void)testANonNumericValueIsAnError
{
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--width", "wide"}, &error));
    XCTAssertNotEqual(error.find("wide"), std::string::npos);
}

- (void)testAZeroSizeIsAnError
{
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--width", "0"}, &error));
}

- (void)testANumberTooLargeForTheFieldIsAnError
{
    // 2^32 truncates to zero in an int, and zero is this parser's word for "not
    // given" — so without a range check a nonsense width would read as a width
    // the caller never typed and quietly keep the current one.
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--width", "4294967296", "--hz", "60"}, &error));
    XCTAssertTrue(ParseFails({"set", "--hz", "99999999999999999999"}, &error));
}

- (void)testAnOptionMissingItsValueDoesNotEatTheNextOption
{
    // Taking `--height` as the width's value reports the wrong option as the
    // bad one, which sends the reader looking in the wrong place.
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--width", "--height", "1080"}, &error));
    XCTAssertNotEqual(error.find("--width"), std::string::npos);
}

- (void)testAScaleMustBeAPositiveNumber
{
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--scale", "wide"}, &error));
    XCTAssertTrue(ParseFails({"set", "--scale", "0"}, &error));
    XCTAssertTrue(ParseFails({"set", "--scale", "2.0x"}, &error));
    XCTAssertEqual(ParsedOK({"set", "--scale", "1.5"}).scale, 1.5);
}

- (void)testAFlagThatTakesNoValueRefusesOne
{
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--force=yes", "--width", "1920"}, &error));
    XCTAssertTrue(ParseFails({"restore", "--all=yes"}, &error));
}

- (void)testHDRAndMirrorTakeOnAndOff
{
    XCTAssertTrue(ParsedOK({"hdr", "on"}).on);
    XCTAssertFalse(ParsedOK({"hdr", "off"}).on);
    XCTAssertEqual(ParsedOK({"mirror", "on"}).kind, EZCommandMirror);
    XCTAssertFalse(ParsedOK({"mirror", "off"}).on);
}

- (void)testHDRWithoutAnAnswerIsAnError
{
    std::string error;
    XCTAssertTrue(ParseFails({"hdr"}, &error));
    XCTAssertTrue(ParseFails({"hdr", "maybe"}, &error));
}

- (void)testColorListsOrSets
{
    XCTAssertEqual(ParsedOK({"color"}).colorAction, EZColorActionList);
    XCTAssertEqual(ParsedOK({"color", "list"}).colorAction, EZColorActionList);

    EZCommandRequest request = ParsedOK({"color", "set", "113"});
    XCTAssertEqual(request.colorAction, EZColorActionSet);
    XCTAssertEqual(request.elementID, 113);
}

- (void)testColorSetNeedsAnElementID
{
    std::string error;
    XCTAssertTrue(ParseFails({"color", "set"}, &error));
    XCTAssertTrue(ParseFails({"color", "set", "brightest"}, &error));
}

- (void)testRestoreNeedsToKnowHowMuchToUndo
{
    XCTAssertTrue(ParsedOK({"restore", "--all"}).everyDisplay);
    XCTAssertFalse(ParsedOK({"restore", "--display", "1"}).everyDisplay);

    std::string error;
    XCTAssertTrue(ParseFails({"restore"}, &error));
}

- (void)testRestoreRefusesToBeToldBothHowMuchToUndo
{
    // Resolving this in --all's favour would remove the overrides for every
    // display when the caller named one, which is not a mistake to make
    // silently.
    std::string error;
    XCTAssertTrue(ParseFails({"restore", "--all", "--display", "1"}, &error));
}

- (void)testForceIsRecognisedWhereverItAppears
{
    XCTAssertTrue(ParsedOK({"set", "--force", "--width", "1920"}).force);
    XCTAssertTrue(ParsedOK({"hdr", "on", "-f"}).force);
}

- (void)testADisplayIsSelectedByIndex
{
    EZDisplaySelector selector = ParsedOK({"modes", "--display", "1"}).display;
    XCTAssertTrue(selector.given);
    XCTAssertTrue(selector.byIndex);
    XCTAssertEqual(selector.index, 1);
}

- (void)testADisplayIsSelectedByVendorAndProduct
{
    EZDisplaySelector selector = ParsedOK({"modes", "-d", "0x610:0x8600"}).display;
    XCTAssertTrue(selector.given);
    XCTAssertFalse(selector.byIndex);
    XCTAssertEqual(selector.vendor, 0x610u);
    XCTAssertEqual(selector.product, 0x8600u);
}

- (void)testAVendorAndProductPairIsReadAsHexWithoutThePrefix
{
    // The listing prints the pair the way the override files spell it, which is
    // hex without a prefix, and a user copies what they see.
    EZDisplaySelector selector = ParsedOK({"modes", "-d", "610:8600"}).display;
    XCTAssertEqual(selector.vendor, 0x610u);
    XCTAssertEqual(selector.product, 0x8600u);
}

- (void)testAMalformedDisplaySelectorIsAnError
{
    std::string error;
    XCTAssertTrue(ParseFails({"modes", "-d", "left"}, &error));
    XCTAssertTrue(ParseFails({"modes", "-d", "610:"}, &error));
    XCTAssertTrue(ParseFails({"modes", "-d", ""}, &error));

    // Attached to the option, because a negative index as a separate token is
    // caught earlier as a missing value and never reaches the selector.
    XCTAssertTrue(ParseFails({"modes", "-d=-1"}, &error));

    // A digit the pair is not written in, and a value too wide for the field
    // the interface reports it in.
    XCTAssertTrue(ParseFails({"modes", "-d", "zz:8600"}, &error));
    XCTAssertTrue(ParseFails({"modes", "-d", "1ffffffff:8600"}, &error));
}

- (void)testEveryCommandRefusesAWordItHasNoUseFor
{
    // Each of these goes to its own branch of the parser, and each of those
    // branches is the only thing standing between a mistyped subcommand and the
    // command running as though the word were not there.
    std::string error;
    XCTAssertTrue(ParseFails({"list", "everything"}, &error));
    XCTAssertTrue(ParseFails({"color", "list", "srgb"}, &error));
    XCTAssertTrue(ParseFails({"color", "sett", "5"}, &error));
    XCTAssertTrue(ParseFails({"set", "1920x1080", "--width", "1920"}, &error));
    XCTAssertTrue(ParseFails({"custom", "list", "1920x1080"}, &error));
    XCTAssertTrue(ParseFails({"restore", "--all", "please"}, &error));
}

- (void)testOptionsThatBelongToAnotherCommandAreRejected
{
    // `mirror` is the whole set of displays, so a display selector on it means
    // the user expects something the command cannot do.
    std::string error;
    XCTAssertTrue(ParseFails({"mirror", "on", "--display", "1"}, &error));
    XCTAssertTrue(ParseFails({"list", "--width", "1920"}, &error));

    // The rest of the table, so widening one command's set is caught rather
    // than merely being possible to catch.
    XCTAssertTrue(ParseFails({"hdr", "on", "--width", "1920"}, &error));
    XCTAssertTrue(ParseFails({"color", "list", "--hz", "60"}, &error));
    XCTAssertTrue(ParseFails({"modes", "--force"}, &error));
    XCTAssertTrue(ParseFails({"restore", "--all", "--force"}, &error));
    XCTAssertTrue(ParseFails({"set", "--width", "1920", "--all"}, &error));
    XCTAssertTrue(ParseFails({"list", "--force"}, &error));
}

- (void)testHelpExplainsOneCommandAtATime
{
    // Every other command refuses a word it does not understand; help saying
    // nothing about the two it was handed would be the odd one out.
    std::string error;
    XCTAssertTrue(ParseFails({"help", "set", "modes"}, &error));
}

- (void)testTheTwoBrightnessTogglesReportThemselvesWhenAskedForNothing
{
    // Unlike `hdr` and `mirror`, which always take a word. These two report
    // state because there is no other way to read it: neither appears in
    // `list`, and Night Shift carries a warmth that a bare on|off cannot show.
    XCTAssertEqual(ParsedOK({"nightshift"}).kind, EZCommandNightShift);
    XCTAssertEqual(ParsedOK({"nightshift"}).toggleAction, EZToggleActionShow);
    XCTAssertEqual(ParsedOK({"truetone"}).kind, EZCommandTrueTone);
    XCTAssertEqual(ParsedOK({"truetone"}).toggleAction, EZToggleActionShow);
}

- (void)testTheTwoBrightnessTogglesTakeOnAndOff
{
    EZCommandRequest on = ParsedOK({"nightshift", "on"});
    XCTAssertEqual(on.toggleAction, EZToggleActionSet);
    XCTAssertTrue(on.on);

    EZCommandRequest off = ParsedOK({"nightshift", "off"});
    XCTAssertEqual(off.toggleAction, EZToggleActionSet);
    XCTAssertFalse(off.on);

    XCTAssertTrue(ParsedOK({"truetone", "on"}).on);
    XCTAssertFalse(ParsedOK({"truetone", "off"}).on);
}

- (void)testNightShiftTakesAWarmthAsAWholePercentage
{
    EZCommandRequest request = ParsedOK({"nightshift", "warmth", "70"});
    XCTAssertEqual(request.kind, EZCommandNightShift);
    XCTAssertEqual(request.toggleAction, EZToggleActionWarmth);
    XCTAssertEqual(request.warmthPercent, 70);

    // Both ends of the scale are values, not mistakes.
    XCTAssertEqual(ParsedOK({"nightshift", "warmth", "0"}).warmthPercent, 0);
    XCTAssertEqual(ParsedOK({"nightshift", "warmth", "100"}).warmthPercent, 100);
}

- (void)testAWarmthOutsideTheScaleIsRefusedRatherThanClamped
{
    // Clamping here would take `warmth 700` — a plain typo for 70 — and set the
    // display to the warmest it goes, reporting success for a number the user
    // never asked for.
    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "warmth", "101"}, &error));
    // The value is quoted back, so the message names the typo rather than
    // leaving the user to spot which of their words was the bad one. Asserted
    // because the parser goes out of its way to embed it, and a generic
    // "invalid warmth" would pass a bare refusal check unnoticed.
    XCTAssertNotEqual(error.find("101"), std::string::npos);

    XCTAssertTrue(ParseFails({"nightshift", "warmth", "700"}, &error));
    XCTAssertNotEqual(error.find("700"), std::string::npos);

    XCTAssertTrue(ParseFails({"nightshift", "warmth", "-1"}, &error));
    XCTAssertNotEqual(error.find("-1"), std::string::npos);

    XCTAssertTrue(ParseFails({"nightshift", "warmth", "half"}, &error));
    XCTAssertNotEqual(error.find("half"), std::string::npos);

    // The two that are about the count of words rather than the value, so they
    // say so instead.
    XCTAssertTrue(ParseFails({"nightshift", "warmth"}, &error));
    XCTAssertNotEqual(error.find("percentage"), std::string::npos);
    XCTAssertTrue(ParseFails({"nightshift", "warmth", "50", "60"}, &error));
    XCTAssertNotEqual(error.find("percentage"), std::string::npos);
}

- (void)testWarmthBelongsToNightShiftAlone
{
    // True Tone has no warmth. Accepting the word would parse to a request the
    // executor has no case for.
    std::string error;
    XCTAssertTrue(ParseFails({"truetone", "warmth", "70"}, &error));
    XCTAssertNotEqual(error.find("warmth"), std::string::npos);
    // And it is refused as an unknown word rather than by suggesting a warmth
    // that True Tone could never take.
    XCTAssertEqual(error.find("or warmth and a percentage"), std::string::npos);
}

- (void)testTheTwoBrightnessTogglesRefuseAWordTheyDoNotKnow
{
    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "warmer"}, &error));
    XCTAssertNotEqual(error.find("warmer"), std::string::npos);

    XCTAssertTrue(ParseFails({"truetone", "auto"}, &error));
    XCTAssertNotEqual(error.find("auto"), std::string::npos);

    // This one reaches the on|off branch and fails on the word count, so it
    // says that rather than naming a word it did understand.
    XCTAssertTrue(ParseFails({"nightshift", "on", "off"}, &error));
    XCTAssertNotEqual(error.find("takes nothing else"), std::string::npos);
}

- (void)testTheTwoBrightnessTogglesAreAboutEveryDisplayAtOnce
{
    // CoreBrightness has no per-display entry point for either, so a selector
    // asks for something neither command can do — the same reason `mirror`
    // refuses one. `--force` goes too: neither toggle blanks the screen, so
    // there is no confirm-or-revert for it to skip.
    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "on", "--display", "1"}, &error));
    XCTAssertNotEqual(error.find("--display"), std::string::npos);
    XCTAssertTrue(ParseFails({"truetone", "on", "-d", "1"}, &error));
    XCTAssertTrue(ParseFails({"nightshift", "on", "--force"}, &error));
    XCTAssertNotEqual(error.find("--force"), std::string::npos);
    XCTAssertTrue(ParseFails({"truetone", "on", "-f"}, &error));

    // The bare reporting form and the warmth form go through the same gate, so
    // both are checked rather than left to the on|off case standing for them.
    XCTAssertTrue(ParseFails({"nightshift", "--display", "1"}, &error));
    XCTAssertTrue(ParseFails({"nightshift", "warmth", "50", "--force"}, &error));
    XCTAssertTrue(ParseFails({"truetone", "--force"}, &error));
}

- (void)testTheTwoBrightnessTogglesTakeJSONOnlyWhenTheyReport
{
    // The same trap `color set` and `custom add` fell into: the flag is gated by
    // command word, and each of these commands covers both a listing and a
    // change. Accepting it on the change would promise output that never comes.
    XCTAssertTrue(ParsedOK({"nightshift", "--json"}).json);
    XCTAssertTrue(ParsedOK({"truetone", "--json"}).json);

    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "on", "--json"}, &error));
    // Named, because the flag is accepted on the bare form of the same command
    // and a message that did not say so would read as a contradiction.
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
    XCTAssertTrue(ParseFails({"nightshift", "warmth", "70", "--json"}, &error));
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
    XCTAssertTrue(ParseFails({"truetone", "off", "--json"}, &error));
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
}

- (void)testNightShiftHandsTheTintBackToItsSchedule
{
    // The third of the three states the menu offers, and the only way back to a
    // schedule once `off` or `on` has taken it away.
    EZCommandRequest request = ParsedOK({"nightshift", "scheduled"});
    XCTAssertEqual(request.kind, EZCommandNightShift);
    XCTAssertEqual(request.toggleAction, EZToggleActionScheduled);
}

- (void)testNightShiftTakesSunsetToSunriseAsASchedule
{
    EZCommandRequest request = ParsedOK({"nightshift", "schedule", "sunset"});
    XCTAssertEqual(request.toggleAction, EZToggleActionSchedule);
    XCTAssertEqual(request.scheduleKind, EZScheduleSunset);
}

- (void)testNightShiftTakesAWindowAsASchedule
{
    EZCommandRequest request = ParsedOK({"nightshift", "schedule", "22:00-07:00"});
    XCTAssertEqual(request.toggleAction, EZToggleActionSchedule);
    XCTAssertEqual(request.scheduleKind, EZScheduleCustom);
    XCTAssertEqual(request.scheduleFrom, 22 * 60);
    XCTAssertEqual(request.scheduleTo, 7 * 60);
}

- (void)testASchedulesWordIsEitherSunsetOrAWindow
{
    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "schedule"}, &error));
    XCTAssertTrue(ParseFails({"nightshift", "schedule", "dusk"}, &error));
    // The message has to name both forms, because a reader who guessed one of
    // them wrong cannot tell from "dusk" alone which of the two they wanted.
    XCTAssertNotEqual(error.find("sunset"), std::string::npos);
    XCTAssertNotEqual(error.find("HH:MM"), std::string::npos);

    // Two schedules and one too many words are the same mistake to the parser,
    // and both have to be refused for the count rather than for the last word
    // happening not to be a schedule.
    XCTAssertTrue(ParseFails({"nightshift", "schedule", "22:00-07:00", "extra"}, &error));
    XCTAssertNotEqual(error.find("one schedule"), std::string::npos);
    XCTAssertTrue(ParseFails({"nightshift", "schedule", "sunset", "22:00-07:00"}, &error));
    XCTAssertNotEqual(error.find("one schedule"), std::string::npos);
}

- (void)testABadWindowIsQuotedBackTheWayABadWarmthIs
{
    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "schedule", "22:00-25:00"}, &error));
    XCTAssertNotEqual(error.find("22:00-25:00"), std::string::npos);
}

- (void)testTheScheduleFormsBelongToNightShiftAlone
{
    // True Tone has no schedule of any kind, so both words have to be refused
    // rather than parsed and quietly ignored by the executor.
    std::string error;
    XCTAssertTrue(ParseFails({"truetone", "scheduled"}, &error));
    XCTAssertNotEqual(error.find("scheduled"), std::string::npos);
    XCTAssertTrue(ParseFails({"truetone", "schedule", "sunset"}, &error));
    XCTAssertNotEqual(error.find("schedule"), std::string::npos);
}

- (void)testTheScheduleFormsChangeSomethingSoTheyRefuseJSON
{
    // Same gate the on|off and warmth forms go through: there is no listing to
    // render, so accepting the flag would promise output that never comes.
    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "scheduled", "--json"}, &error));
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
    XCTAssertTrue(ParseFails({"nightshift", "schedule", "sunset", "--json"}, &error));
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
}

- (void)testTheScheduleFormsAreAboutEveryDisplayAtOnce
{
    std::string error;
    XCTAssertTrue(ParseFails({"nightshift", "scheduled", "--display", "1"}, &error));
    XCTAssertNotEqual(error.find("--display"), std::string::npos);
    XCTAssertTrue(ParseFails({"nightshift", "schedule", "sunset", "--force"}, &error));
    XCTAssertNotEqual(error.find("--force"), std::string::npos);
}

- (void)testNightShiftsHelpNamesTheSubcommandNobodyWouldGuess
{
    // `on` and `off` are the shape every other toggle has, so a reader can find
    // them without being told. `warmth` is only in this one command, and the
    // scale it takes is not implied by the word.
    std::string usage = EZUsageText("nightshift");
    XCTAssertNotEqual(usage.find("warmth"), std::string::npos);
    XCTAssertNotEqual(usage.find("0-100"), std::string::npos);
    XCTAssertNotEqual(usage.find("scheduled"), std::string::npos);
    XCTAssertNotEqual(usage.find("HH:MM-HH:MM"), std::string::npos);

    // The general listing has to name them too. A reader who never asks for
    // this topic would otherwise not learn that a schedule can be set at all,
    // which is how `schedule` came to be missing from that line once already.
    std::string general = EZUsageText("");
    XCTAssertNotEqual(general.find("scheduled"), std::string::npos);
    XCTAssertNotEqual(general.find("schedule\n"), std::string::npos);
}

- (void)testBrightnessesHelpGivesTheScaleAndSaysWhichDialItIs
{
    std::string usage = EZUsageText("brightness");

    // The scale, because "brightness 200" is otherwise a reasonable guess.
    XCTAssertNotEqual(usage.find("0-100"), std::string::npos);

    // The selector, because this is the only one of the three display settings
    // that belongs to a display rather than to the machine.
    XCTAssertNotEqual(usage.find("--display"), std::string::npos);

    // Which dial it moves. Someone whose monitor has its own brightness buttons
    // has two, and nothing but this sentence says these are not the same one.
    XCTAssertNotEqual(usage.find("brightness keys"), std::string::npos);
}

- (void)testBrightnessReportsItselfWhenAskedForNothing
{
    // The same shape as the two toggles: there is no other way to read the
    // value, because brightness does not appear in `list`.
    XCTAssertEqual(ParsedOK({"brightness"}).kind, EZCommandBrightness);
    XCTAssertEqual(ParsedOK({"brightness"}).toggleAction, EZToggleActionShow);
}

- (void)testBrightnessTakesAWholePercentage
{
    // No `set` word in front of the number, unlike `nightshift warmth 70`.
    // Brightness has only the one thing to change, so a word to say which would
    // be a word with one possible value.
    EZCommandRequest request = ParsedOK({"brightness", "40"});
    XCTAssertEqual(request.kind, EZCommandBrightness);
    XCTAssertEqual(request.toggleAction, EZToggleActionSet);
    XCTAssertEqual(request.brightnessPercent, 40);

    // Both ends of the scale are values, not mistakes. Zero especially: a
    // display can be dimmed all the way, and refusing it would make the command
    // line unable to reach a state the function keys reach.
    XCTAssertEqual(ParsedOK({"brightness", "0"}).brightnessPercent, 0);
    XCTAssertEqual(ParsedOK({"brightness", "100"}).brightnessPercent, 100);
}

- (void)testABrightnessOutsideTheScaleIsRefusedRatherThanClamped
{
    // As with `nightshift warmth`: clamping would read `brightness 700` — a
    // typo for 70 — as full brightness and report success for it.
    std::string error;
    XCTAssertTrue(ParseFails({"brightness", "101"}, &error));
    XCTAssertNotEqual(error.find("101"), std::string::npos);

    XCTAssertTrue(ParseFails({"brightness", "700"}, &error));
    XCTAssertNotEqual(error.find("700"), std::string::npos);

    XCTAssertTrue(ParseFails({"brightness", "-1"}, &error));
    XCTAssertNotEqual(error.find("-1"), std::string::npos);

    XCTAssertTrue(ParseFails({"brightness", "half"}, &error));
    XCTAssertNotEqual(error.find("half"), std::string::npos);

    // Two numbers is about the count of words rather than either value, so the
    // message says so instead of quoting one of them back.
    XCTAssertTrue(ParseFails({"brightness", "50", "60"}, &error));
    XCTAssertNotEqual(error.find("percentage"), std::string::npos);
}

- (void)testBrightnessBelongsToOneDisplayRatherThanToTheMachine
{
    // The opposite of Night Shift and True Tone. DisplayServices takes a display
    // ID for every call, so a selector is the whole point rather than something
    // the command cannot honour.
    EZCommandRequest request = ParsedOK({"brightness", "40", "--display", "2"});
    XCTAssertTrue(request.display.given);
    XCTAssertTrue(request.display.byIndex);
    XCTAssertEqual(request.display.index, 2);
    XCTAssertTrue(ParsedOK({"brightness", "-d", "2"}).display.given);

    // `--force` still goes: it skips the confirm-or-revert countdown, and
    // brightness has none because no value of it blanks the screen for good.
    std::string error;
    XCTAssertTrue(ParseFails({"brightness", "40", "--force"}, &error));
    XCTAssertNotEqual(error.find("--force"), std::string::npos);
}

- (void)testBrightnessTakesJSONOnlyWhenItReports
{
    XCTAssertTrue(ParsedOK({"brightness", "--json"}).json);

    std::string error;
    XCTAssertTrue(ParseFails({"brightness", "40", "--json"}, &error));
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
}

- (void)testABrightnessIsAWholeNumberWithoutItsUnit
{
    // Both are the slips a percentage invites, and both are refused today only
    // because ParseWholeNumber happens to reject a non-digit. Nail that down
    // here, so a looser number parser cannot quietly start reading "50%" as 50
    // and "50.5" as 50.
    std::string error;
    XCTAssertTrue(ParseFails({"brightness", "50%"}, &error));
    XCTAssertNotEqual(error.find("50%"), std::string::npos);

    XCTAssertTrue(ParseFails({"brightness", "50.5"}, &error));
    XCTAssertNotEqual(error.find("50.5"), std::string::npos);
}

@end


#pragma mark - Volume and mute

@interface VolumeParsingTests : XCTestCase
@end

@implementation VolumeParsingTests

- (void)testVolumeHelpSaysWhoseSpeakersTheseAre
{
    std::string usage = EZUsageText("volume");

    XCTAssertNotEqual(usage.find("0-100"), std::string::npos);
    XCTAssertNotEqual(usage.find("--display"), std::string::npos);

    // The one sentence that stops this being read as the Mac's output volume.
    // They are separate dials, and moving the wrong one is silent: the sound
    // gets quieter either way, and only the monitor's own display says which.
    XCTAssertNotEqual(usage.find("monitor"), std::string::npos);
}

- (void)testVolumeReportsItselfWhenAskedForNothing
{
    XCTAssertEqual(ParsedOK({"volume"}).kind, EZCommandVolume);
    XCTAssertEqual(ParsedOK({"volume"}).toggleAction, EZToggleActionShow);
}

- (void)testVolumeTakesAWholePercentage
{
    // The same shape as brightness, deliberately: one dial, so no word in front
    // of the number, and the percentage is this project's unit even though the
    // display's own range is whatever it published.
    EZCommandRequest request = ParsedOK({"volume", "40"});
    XCTAssertEqual(request.kind, EZCommandVolume);
    XCTAssertEqual(request.toggleAction, EZToggleActionSet);
    XCTAssertEqual(request.volumePercent, 40);

    XCTAssertEqual(ParsedOK({"volume", "0"}).volumePercent, 0);
    XCTAssertEqual(ParsedOK({"volume", "100"}).volumePercent, 100);
}

- (void)testAVolumeOutsideTheScaleIsRefusedRatherThanClamped
{
    std::string error;
    XCTAssertTrue(ParseFails({"volume", "101"}, &error));
    XCTAssertNotEqual(error.find("101"), std::string::npos);

    XCTAssertTrue(ParseFails({"volume", "700"}, &error));
    XCTAssertNotEqual(error.find("700"), std::string::npos);

    XCTAssertTrue(ParseFails({"volume", "loud"}, &error));
    XCTAssertNotEqual(error.find("loud"), std::string::npos);

    XCTAssertTrue(ParseFails({"volume", "50", "60"}, &error));
    XCTAssertNotEqual(error.find("percentage"), std::string::npos);

    // Below the scale as well as above it. Volume shares its parsing arm with
    // brightness, which tests this — and a shared arm is exactly where an
    // untested half stops being covered the moment someone splits it.
    XCTAssertTrue(ParseFails({"volume", "-1"}, &error));
    XCTAssertNotEqual(error.find("-1"), std::string::npos);
}

- (void)testAVolumeIsAWholeNumberWithoutItsUnit
{
    // The same two slips a percentage invites, refused for the same reason as
    // for brightness: ParseWholeNumber rejects a non-digit, and nothing else
    // stops "50%" being read as 50.
    std::string error;
    XCTAssertTrue(ParseFails({"volume", "50%"}, &error));
    XCTAssertNotEqual(error.find("50%"), std::string::npos);

    XCTAssertTrue(ParseFails({"volume", "50.5"}, &error));
    XCTAssertNotEqual(error.find("50.5"), std::string::npos);
}

- (void)testVolumeAndMuteBelongToOneDisplayAndTakeNoCountdown
{
    EZCommandRequest request = ParsedOK({"volume", "40", "--display", "2"});
    XCTAssertTrue(request.display.given);
    XCTAssertTrue(request.display.byIndex);
    XCTAssertEqual(request.display.index, 2);
    XCTAssertTrue(ParsedOK({"mute", "on", "-d", "2"}).display.given);

    // `--force` skips the confirm-or-revert countdown, and neither of these has
    // one: a monitor at the wrong volume is audible and reversible, unlike a
    // resolution that leaves nothing on screen to click.
    std::string error;
    XCTAssertTrue(ParseFails({"volume", "40", "--force"}, &error));
    XCTAssertTrue(ParseFails({"mute", "on", "--force"}, &error));
}

- (void)testVolumeBelongsToOneDisplay
{
    EZCommandRequest request = ParsedOK({"volume", "40", "--display", "2"});
    XCTAssertTrue(request.display.given);
    XCTAssertTrue(request.display.byIndex);
    XCTAssertEqual(request.display.index, 2);
}

- (void)testVolumeTakesJSONOnlyWhenItReports
{
    XCTAssertTrue(ParsedOK({"volume", "--json"}).json);

    std::string error;
    XCTAssertTrue(ParseFails({"volume", "40", "--json"}, &error));
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
}

- (void)testMuteReadsAsATogglePerDisplay
{
    // Mute is the one setting here shaped like Night Shift rather than like
    // brightness, because it has two states rather than a scale — but it still
    // belongs to a display, so it keeps the selector the two machine-wide
    // toggles have no use for.
    XCTAssertEqual(ParsedOK({"mute"}).kind, EZCommandMute);
    XCTAssertEqual(ParsedOK({"mute"}).toggleAction, EZToggleActionShow);

    EZCommandRequest on = ParsedOK({"mute", "on", "--display", "2"});
    XCTAssertEqual(on.toggleAction, EZToggleActionSet);
    XCTAssertTrue(on.on);
    XCTAssertEqual(on.display.index, 2);

    XCTAssertFalse(ParsedOK({"mute", "off"}).on);
}

- (void)testMuteRefusesAnythingThatIsNotOnOrOff
{
    std::string error;
    XCTAssertTrue(ParseFails({"mute", "toggle"}, &error));
    XCTAssertNotEqual(error.find("toggle"), std::string::npos);

    // As everywhere else: the flag belongs to the bare reporting form.
    XCTAssertTrue(ParsedOK({"mute", "--json"}).json);
    XCTAssertTrue(ParseFails({"mute", "on", "--json"}, &error));
    XCTAssertNotEqual(error.find("--json"), std::string::npos);
}

@end


#pragma mark - The usage text

@interface UsageTextTests : XCTestCase
@end

@implementation UsageTextTests

- (void)testTheGeneralTextListsEveryCommand
{
    std::string usage = EZUsageText("");
    for (const std::string &command : {"list", "modes", "set", "hdr", "mirror",
                                       "color", "restore", "custom", "prefs",
                                       "nightshift", "truetone", "brightness",
                                       "volume", "mute", "help", "version"})
        XCTAssertNotEqual(usage.find(command), std::string::npos,
                          @"the usage text does not mention %s", command.c_str());
}

- (void)testEveryCommandExplainsItself
{
    // A command with no text of its own falls back to the general listing,
    // which reads as though `help` did not understand the name.
    for (const std::string &command : {"list", "modes", "set", "hdr", "mirror",
                                       "color", "restore", "custom", "prefs",
                                       "nightshift", "truetone", "brightness",
                                       "volume", "mute", "version"})
        XCTAssertNotEqual(EZUsageText(command), EZUsageText(""),
                          @"%s has no help of its own", command.c_str());
}

- (void)testThePreferenceHelpNamesEveryPreference
{
    std::string usage = EZUsageText("prefs");
    for (const EZPreferenceInfo &preference : EZPreferences())
        XCTAssertNotEqual(usage.find(preference.name), std::string::npos,
                          @"prefs help does not mention %s", preference.name.c_str());
}

- (void)testACommandsTextDescribesItsOwnOptions
{
    std::string usage = EZUsageText("set");
    XCTAssertNotEqual(usage.find("--width"), std::string::npos);
    XCTAssertNotEqual(usage.find("--hz"), std::string::npos);
}

- (void)testAnUnknownTopicFallsBackToTheGeneralText
{
    XCTAssertEqual(EZUsageText("bits"), EZUsageText(""));
}

@end


#pragma mark - The version text

@interface VersionTextTests : XCTestCase
@end

@implementation VersionTextTests

- (void)testTheVersionTextCarriesBothNumbers
{
    // Two numbers, because they answer different questions. The short version
    // is what a release is called and what the updater compares; the build is
    // what tells two builds of the same release apart.
    XCTAssertEqual(EZVersionText("1.2.3", "45"), std::string("ezdisplay 1.2.3 (45)\n"));
}

- (void)testAMissingBuildLeavesOutTheParentheses
{
    // The build comes from the bundle, so a hand-edited Info.plist can leave it
    // out. "ezdisplay 1.2.3 ()" would read as a build numbered nothing.
    XCTAssertEqual(EZVersionText("1.2.3", ""), std::string("ezdisplay 1.2.3\n"));
}

@end


#pragma mark - The zero-to-one scale

@interface PercentScaleTests : XCTestCase
@end

@implementation PercentScaleTests

- (void)testTheScaleEndsAndItsMiddleMapBothWays
{
    XCTAssertEqualWithAccuracy(EZFractionFromPercent(0),   0.0f, 0.0001);
    XCTAssertEqualWithAccuracy(EZFractionFromPercent(50),  0.5f, 0.0001);
    XCTAssertEqualWithAccuracy(EZFractionFromPercent(100), 1.0f, 0.0001);

    XCTAssertEqual(EZPercentFromFraction(0.0f), 0);
    XCTAssertEqual(EZPercentFromFraction(0.5f), 50);
    XCTAssertEqual(EZPercentFromFraction(1.0f), 100);
}

- (void)testEveryPercentageSurvivesTheRoundTrip
{
    // The two halves are used together — a value set from the command line is
    // read back by the same command's listing — so a percentage that comes back
    // as its neighbour would report a value nobody set. Truncating instead of
    // rounding does exactly that: 0.07f * 100 is 6.999999 in float.
    for (int percent = 0; percent <= 100; percent++)
        XCTAssertEqual(EZPercentFromFraction(EZFractionFromPercent(percent)), percent,
                       @"%d did not survive the round trip", percent);
}

- (void)testAValueFromElsewhereIsRoundedToTheNearestPercent
{
    // Both frameworks hold a float, and nothing stops System Settings or the
    // brightness keys leaving one between two percentages. Rounding down would
    // show 42% for a value nearer 43.
    XCTAssertEqual(EZPercentFromFraction(0.426f), 43);
    XCTAssertEqual(EZPercentFromFraction(0.424f), 42);
}

- (void)testAValueOffEitherEndOfTheScaleIsClamped
{
    // No caller can produce one today: the parser refuses a percentage outside
    // 0 to 100, and a slider cannot leave its track. The clamp is what stops a
    // later caller handing a private API a value it never promised to take,
    // which is not a call worth finding out the behavior of.
    XCTAssertEqualWithAccuracy(EZFractionFromPercent(-40), 0.0f, 0.0001);
    XCTAssertEqualWithAccuracy(EZFractionFromPercent(140), 1.0f, 0.0001);

    XCTAssertEqual(EZPercentFromFraction(-0.4f), 0);
    XCTAssertEqual(EZPercentFromFraction(1.4f), 100);
}

@end


#pragma mark - Night Shift schedule

@interface ScheduleParsingTests : XCTestCase
@end

@implementation ScheduleParsingTests

- (void)testAClockTimeBecomesMinutesPastMidnight
{
    XCTAssertEqual(EZParseTimeOfDay("00:00"), 0);
    XCTAssertEqual(EZParseTimeOfDay("07:00"), 7 * 60);
    XCTAssertEqual(EZParseTimeOfDay("22:30"), 22 * 60 + 30);
    XCTAssertEqual(EZParseTimeOfDay("23:59"), 23 * 60 + 59);
}

- (void)testAOneDigitHourIsHowAPersonWritesIt
{
    // `9:00` is nine o'clock everywhere outside a timetable, so refusing it
    // would be pedantry rather than safety.
    XCTAssertEqual(EZParseTimeOfDay("9:00"), 9 * 60);
    XCTAssertEqual(EZParseTimeOfDay("0:05"), 5);
}

- (void)testAOneDigitMinuteIsRefusedBecauseItHasTwoReadings
{
    // `9:5` is as likely a slip for `9:50` as for `9:05`, and picking either
    // sets a schedule an hour out from the one that was meant.
    XCTAssertEqual(EZParseTimeOfDay("9:5"), -1);
    XCTAssertEqual(EZParseTimeOfDay("22:3"), -1);
}

- (void)testATimeOffTheClockIsRefused
{
    XCTAssertEqual(EZParseTimeOfDay("24:00"), -1);
    XCTAssertEqual(EZParseTimeOfDay("22:60"), -1);
    XCTAssertEqual(EZParseTimeOfDay("-1:00"), -1);
    XCTAssertEqual(EZParseTimeOfDay("999:00"), -1);
}

- (void)testAnythingThatIsNotAClockTimeIsRefused
{
    XCTAssertEqual(EZParseTimeOfDay(""), -1);
    XCTAssertEqual(EZParseTimeOfDay("22"), -1);
    XCTAssertEqual(EZParseTimeOfDay("22:"), -1);
    XCTAssertEqual(EZParseTimeOfDay(":30"), -1);
    XCTAssertEqual(EZParseTimeOfDay("22:00:00"), -1);
    XCTAssertEqual(EZParseTimeOfDay("ten:00"), -1);
    XCTAssertEqual(EZParseTimeOfDay("22:0o"), -1);
    // A sign the number parser might take but a clock never writes.
    XCTAssertEqual(EZParseTimeOfDay("+9:00"), -1);
    XCTAssertEqual(EZParseTimeOfDay("22:+0"), -1);
}

- (void)testAWindowSplitsIntoItsTwoEnds
{
    int from = -1, to = -1;
    XCTAssertTrue(EZParseScheduleWindow("22:00-07:00", &from, &to));
    XCTAssertEqual(from, 22 * 60);
    XCTAssertEqual(to, 7 * 60);
}

- (void)testAWindowRunningPastMidnightIsTheOrdinaryCase
{
    // The schedule macOS ships with runs backwards by the clock, so a check
    // that from is before to would refuse the common one.
    int from = 0, to = 0;
    XCTAssertTrue(EZParseScheduleWindow("22:00-07:00", &from, &to));
    XCTAssertGreaterThan(from, to);

    // And one that does not wrap is equally fine.
    XCTAssertTrue(EZParseScheduleWindow("09:00-17:30", &from, &to));
    XCTAssertLessThan(from, to);
}

- (void)testAWindowWithNoLengthIsRefused
{
    // Both ends on the same minute describes no span at all, and macOS is not
    // documented to say which way it reads one.
    int from = 0, to = 0;
    XCTAssertFalse(EZParseScheduleWindow("22:00-22:00", &from, &to));
}

- (void)testAWindowMissingAPartIsRefused
{
    int from = 0, to = 0;
    XCTAssertFalse(EZParseScheduleWindow("", &from, &to));
    XCTAssertFalse(EZParseScheduleWindow("22:00", &from, &to));
    XCTAssertFalse(EZParseScheduleWindow("22:00-", &from, &to));
    XCTAssertFalse(EZParseScheduleWindow("-07:00", &from, &to));
    XCTAssertFalse(EZParseScheduleWindow("22:00-07:00-09:00", &from, &to));
    XCTAssertFalse(EZParseScheduleWindow("22:00 - 07:00", &from, &to));
    XCTAssertFalse(EZParseScheduleWindow("22:00-25:00", &from, &to));
}

- (void)testARefusedWindowLeavesTheOutputsAlone
{
    // The caller reports an error rather than reading these back, but a
    // half-written pair is the kind of thing a later caller trips over.
    int from = 111, to = 222;
    XCTAssertFalse(EZParseScheduleWindow("22:00-nonsense", &from, &to));
    XCTAssertEqual(from, 111);
    XCTAssertEqual(to, 222);
}

@end


#pragma mark - Choosing the display

@interface DisplayResolutionTests : XCTestCase
@end

@implementation DisplayResolutionTests

/// Two different monitors, and the main display first, as the display list
/// reports them.
static std::vector<EZDisplayIdentity> TwoDisplays()
{
    return {{0, 0x610, 0xa050, true}, {1, 0x489, 0x8600, false}};
}

- (void)testNoSelectorMeansTheMainDisplay
{
    EZDisplaySelector selector;
    XCTAssertEqual(EZResolveDisplay(TwoDisplays(), selector), 0);
}

- (void)testTheMainDisplayIsFoundWhereverTheListPutsIt
{
    // The list is whatever order the interface reported, and only one of its
    // entries says it is the main display. Taking the first entry instead would
    // aim every unqualified command at the wrong monitor.
    std::vector<EZDisplayIdentity> displays = {{0, 0x610, 0xa050, false},
                                               {1, 0x489, 0x8600, true}};

    EZDisplaySelector selector;
    XCTAssertEqual(EZResolveDisplay(displays, selector), 1);
}

- (void)testWithNothingMarkedMainTheFirstDisplayIsUsed
{
    // Nothing should reach this: the display the window server draws the menu
    // bar on is always in the list. Falling back to the first entry rather than
    // failing keeps a command working if that ever stops being true.
    std::vector<EZDisplayIdentity> displays = {{0, 0x610, 0xa050, false},
                                               {1, 0x489, 0x8600, false}};

    EZDisplaySelector selector;
    XCTAssertEqual(EZResolveDisplay(displays, selector), 0);
}

- (void)testNoDisplaysAtAllFindsNothing
{
    // A Mac with the lid shut and nothing plugged in. This is the only guard
    // between that and indexing an empty list, so it is checked for both the
    // default display and a named one.
    EZDisplaySelector none;
    XCTAssertEqual(EZResolveDisplay({}, none), EZDisplayNotFound);

    EZDisplaySelector byIndex;
    byIndex.given = true;
    byIndex.byIndex = true;
    byIndex.index = 0;
    XCTAssertEqual(EZResolveDisplay({}, byIndex), EZDisplayNotFound);

    EZDisplaySelector byPair;
    byPair.given = true;
    byPair.vendor = 0x610;
    byPair.product = 0xa050;
    XCTAssertEqual(EZResolveDisplay({}, byPair), EZDisplayNotFound);
}

- (void)testAnIndexPicksThatPosition
{
    EZDisplaySelector selector;
    selector.given = true;
    selector.byIndex = true;
    selector.index = 1;
    XCTAssertEqual(EZResolveDisplay(TwoDisplays(), selector), 1);
}

- (void)testAnIndexPastTheEndFindsNothing
{
    EZDisplaySelector selector;
    selector.given = true;
    selector.byIndex = true;
    selector.index = 5;
    XCTAssertEqual(EZResolveDisplay(TwoDisplays(), selector), EZDisplayNotFound);
}

- (void)testAVendorAndProductPairPicksItsDisplay
{
    EZDisplaySelector selector;
    selector.given = true;
    selector.vendor = 0x489;
    selector.product = 0x8600;
    XCTAssertEqual(EZResolveDisplay(TwoDisplays(), selector), 1);
}

- (void)testAPairNoDisplayReportsFindsNothing
{
    EZDisplaySelector selector;
    selector.given = true;
    selector.vendor = 0x111;
    selector.product = 0x222;
    XCTAssertEqual(EZResolveDisplay(TwoDisplays(), selector), EZDisplayNotFound);
}

- (void)testTwoIdenticalMonitorsAreAmbiguousRatherThanACoinToss
{
    std::vector<EZDisplayIdentity> pair = {{0, 0x610, 0xa050}, {1, 0x610, 0xa050}};

    EZDisplaySelector selector;
    selector.given = true;
    selector.vendor = 0x610;
    selector.product = 0xa050;
    XCTAssertEqual(EZResolveDisplay(pair, selector), EZDisplayAmbiguous);
}

- (void)testAnIndexStillSeparatesTwoIdenticalMonitors
{
    std::vector<EZDisplayIdentity> pair = {{0, 0x610, 0xa050}, {1, 0x610, 0xa050}};

    EZDisplaySelector selector;
    selector.given = true;
    selector.byIndex = true;
    selector.index = 1;
    XCTAssertEqual(EZResolveDisplay(pair, selector), 1);
}

@end


#pragma mark - Choosing the mode

@interface ModeChoiceTests : XCTestCase
@end

@implementation ModeChoiceTests

/// One geometry at three rates, a second geometry at three more, and a
/// standard-scale entry, which is the shape that made the old first-match loop
/// arbitrary.
///
/// The second geometry's rates are deliberately out of order, with the fastest
/// neither first nor last in the list. Choosing the first or the last entry
/// would then give the wrong answer, which a fixture in rate order would let
/// through.
static std::vector<EZModeCandidate> SampleModes()
{
    return {
        {0, 3008, 1692,  60, 2.0},
        {1, 3008, 1692, 120, 2.0},
        {2, 3008, 1692, 144, 2.0},
        {3, 1920, 1080,  60, 2.0},
        {4, 1920, 1080,  60, 1.0},
        {5, 1920, 1080,  75, 2.0},
        {6, 1920, 1080,  50, 2.0},
    };
}

static EZCommandRequest SetRequest()
{
    EZCommandRequest request;
    request.kind = EZCommandSet;
    return request;
}

- (void)testTheRequestedRateIsTheOneChosen
{
    EZCommandRequest request = SetRequest();
    request.width = 3008;
    request.height = 1692;
    request.refreshHz = 144;

    XCTAssertEqual(EZChooseMode(SampleModes(), request, SampleModes()[0]), 2);
}

- (void)testARateNoModeOffersFailsRatherThanLandingElsewhere
{
    // The old loop ignored the rate entirely and applied its first geometry
    // match, so asking for 240 Hz quietly gave you 60.
    EZCommandRequest request = SetRequest();
    request.width = 3008;
    request.height = 1692;
    request.refreshHz = 240;

    XCTAssertEqual(EZChooseMode(SampleModes(), request, SampleModes()[0]), -1);
}

- (void)testWithNoRateAskedForTheCurrentOneIsKept
{
    EZCommandRequest request = SetRequest();
    request.width = 3008;
    request.height = 1692;

    XCTAssertEqual(EZChooseMode(SampleModes(), request, SampleModes()[1]), 1);
}

- (void)testWhereTheCurrentRateIsNotOfferedTheHighestIsTaken
{
    // Switching from 3008x1692 at 144 Hz to a geometry that does 60, 75, and
    // 50. The rate has to move, and 75 is neither the first of those listed nor
    // the last, so only comparing them gives the right answer.
    EZCommandRequest request = SetRequest();
    request.width = 1920;
    request.height = 1080;

    XCTAssertEqual(EZChooseMode(SampleModes(), request, SampleModes()[2]), 5);
}

- (void)testWhatIsLeftOutComesFromTheCurrentMode
{
    // Width alone, from the 1.0-scale 1920x1080 entry: the scale is kept, so
    // the HiDPI mode of the same geometry is not the answer.
    EZCommandRequest request = SetRequest();
    request.width = 1920;

    XCTAssertEqual(EZChooseMode(SampleModes(), request, SampleModes()[4]), 4);
}

- (void)testHeightAloneAndScaleAloneAlsoComeFromTheCurrentMode
{
    // Height alone, from the HiDPI 3008x1692 entry: the width and the scale are
    // kept, and no mode offers 3008 wide by 1080 high, so this fails rather
    // than dropping one of them.
    EZCommandRequest byHeight = SetRequest();
    byHeight.height = 1080;
    XCTAssertEqual(EZChooseMode(SampleModes(), byHeight, SampleModes()[1]), -1);

    // Scale alone, from the standard-scale 1920x1080 entry: the geometry is
    // kept and only the scale moves, which is the HiDPI entry of the same size.
    EZCommandRequest byScale = SetRequest();
    byScale.scale = 2.0;
    XCTAssertEqual(EZChooseMode(SampleModes(), byScale, SampleModes()[4]), 3);
}

- (void)testTwoModesDifferingOnlyInScaleAreNotTheSameMode
{
    // The listing marks the mode in force with a star, and 1920x1080 at 60Hz
    // exists here at both scales. A comparison that left the scale out would
    // star both rows and tell the user they are running two modes at once.
    XCTAssertFalse(EZSameMode(SampleModes()[3], SampleModes()[4]));
    XCTAssertTrue(EZSameMode(SampleModes()[3], SampleModes()[3]));

    // The number is which entry of the private list it is, not part of what the
    // mode is: the same mode reported twice is still one mode.
    EZModeCandidate again = SampleModes()[3];
    again.number = 99;
    XCTAssertTrue(EZSameMode(SampleModes()[3], again));
}

- (void)testAScaleNoModeOffersAtThatGeometryFails
{
    EZCommandRequest request = SetRequest();
    request.width = 3008;
    request.height = 1692;
    request.scale = 1.0;

    XCTAssertEqual(EZChooseMode(SampleModes(), request, SampleModes()[0]), -1);
}

- (void)testFilteringNarrowsTheListingWithoutChoosing
{
    EZCommandRequest request;
    request.kind = EZCommandModes;
    request.refreshHz = 60;

    std::vector<EZModeCandidate> filtered = EZFilterModes(SampleModes(), request);
    XCTAssertEqual(filtered.size(), 3u);
}

- (void)testAnEmptyFilterKeepsEverything
{
    EZCommandRequest request;
    request.kind = EZCommandModes;

    XCTAssertEqual(EZFilterModes(SampleModes(), request).size(), SampleModes().size());
}

- (void)testDuplicatesCollapseAndTheFirstOfEachSurvives
{
    std::vector<EZModeCandidate> raw = {
        {0, 3008, 1692, 120, 2.0},
        {1, 3008, 1692, 120, 2.0},
        {2, 3008, 1692,  60, 2.0},
        {3, 3008, 1692, 120, 2.0},
    };

    std::vector<EZModeCandidate> deduped = EZDedupeModes(raw);
    XCTAssertEqual(deduped.size(), 2u);
    XCTAssertEqual(deduped[0].number, 0);
    XCTAssertEqual(deduped[1].number, 2);
}

@end


#pragma mark - Confirm or revert

@interface ConfirmationPolicyTests : XCTestCase
@end

@implementation ConfirmationPolicyTests

- (void)testAnInteractiveTerminalIsAsked
{
    XCTAssertTrue(EZShouldPrompt(/* force */ false, /* interactive */ true));
}

- (void)testAScriptIsNotAsked
{
    // Nobody is there to answer, so a countdown would revert every automated
    // change 20 seconds later.
    XCTAssertFalse(EZShouldPrompt(false, false));
}

- (void)testForceSkipsTheQuestion
{
    XCTAssertFalse(EZShouldPrompt(true, true));
}

- (void)testOnlyAnExplicitYesKeepsTheChange
{
    XCTAssertTrue(EZAnswerKeeps("y"));
    XCTAssertTrue(EZAnswerKeeps("Y"));
    XCTAssertTrue(EZAnswerKeeps("yes"));
    XCTAssertTrue(EZAnswerKeeps("YES\n"));
    XCTAssertTrue(EZAnswerKeeps("  y  "));
}

- (void)testEveryOtherAnswerReverts
{
    XCTAssertFalse(EZAnswerKeeps(""));
    XCTAssertFalse(EZAnswerKeeps("\n"));
    XCTAssertFalse(EZAnswerKeeps("n"));
    XCTAssertFalse(EZAnswerKeeps("no"));
    XCTAssertFalse(EZAnswerKeeps("yeah"));
    XCTAssertFalse(EZAnswerKeeps("k"));
}

- (void)testEndOfInputReverts
{
    // The terminal closed, or the answer was piped in and ran out. Either way
    // nobody said keep.
    XCTAssertFalse(EZAnswerKeeps(NULL));
}

@end


#pragma mark - Custom resolutions

@interface CustomResolutionParsingTests : XCTestCase
@end

@implementation CustomResolutionParsingTests

- (void)testCustomOnItsOwnLists
{
    // Same shape as `color`: the listing is the harmless action, so it is the
    // one you get for typing the command and nothing else.
    XCTAssertEqual(ParsedOK({"custom"}).kind, EZCommandCustom);
    XCTAssertEqual(ParsedOK({"custom"}).customAction, EZCustomActionList);
    XCTAssertEqual(ParsedOK({"custom", "list"}).customAction, EZCustomActionList);
}

- (void)testAddTakesTheResolutionTheUserWantsToSee
{
    EZCommandRequest request = ParsedOK({"custom", "add", "--width", "1920", "--height", "1080"});
    XCTAssertEqual(request.customAction, EZCustomActionAdd);
    XCTAssertEqual(request.width, 1920);
    XCTAssertEqual(request.height, 1080);
    XCTAssertFalse(request.hiDPI);
}

- (void)testTheHiDPIFlagIsCarried
{
    XCTAssertTrue(ParsedOK({"custom", "add", "--width", "1920", "--height", "1080", "--hidpi"}).hiDPI);
}

- (void)testAddAndRemoveBothNeedAWholeResolution
{
    std::string error;
    XCTAssertTrue(ParseFails({"custom", "add", "--width", "1920"}, &error));
    XCTAssertTrue(ParseFails({"custom", "add", "--height", "1080"}, &error));
    XCTAssertTrue(ParseFails({"custom", "add"}, &error));
    XCTAssertTrue(ParseFails({"custom", "remove", "--width", "1920"}, &error));
    XCTAssertTrue(ParseFails({"custom", "remove"}, &error));
}

- (void)testRemoveNamesTheResolutionToDrop
{
    EZCommandRequest request = ParsedOK({"custom", "remove", "--width", "1600", "--height", "900"});
    XCTAssertEqual(request.customAction, EZCustomActionRemove);
    XCTAssertEqual(request.width, 1600);
    XCTAssertEqual(request.height, 900);
}

- (void)testListingTakesNoResolution
{
    // Given a size, `custom list` would look like it filters, and it does not.
    std::string error;
    XCTAssertTrue(ParseFails({"custom", "list", "--width", "1920"}, &error));
    XCTAssertTrue(ParseFails({"custom", "--hidpi"}, &error));
}

- (void)testAnUnknownActionIsRefused
{
    std::string error;
    XCTAssertTrue(ParseFails({"custom", "fish"}, &error));
    XCTAssertTrue(ParseFails({"custom", "add", "extra", "--width", "1", "--height", "1"}, &error));
}

- (void)testHiDPIBelongsToCustomAlone
{
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--width", "1920", "--hidpi"}, &error));
    XCTAssertTrue(ParseFails({"modes", "--hidpi"}, &error));
}

- (void)testRemoveRefusesTheHiDPIFlag
{
    // Remove drops every custom entry of that size, so the flag would narrow
    // nothing. Accepting and ignoring it would say the opposite.
    std::string error;
    XCTAssertTrue(ParseFails({"custom", "remove", "--width", "1", "--height", "1", "--hidpi"},
                             &error));
}

- (void)testTheHiDPIFlagTakesNoValue
{
    std::string error;
    XCTAssertTrue(ParseFails({"custom", "add", "--width", "1", "--height", "1", "--hidpi=yes"}, &error));
}

- (void)testCustomTakesADisplay
{
    EZCommandRequest request = ParsedOK({"custom", "list", "--display", "1"});
    XCTAssertTrue(request.display.given);
    XCTAssertEqual(request.display.index, 1);
}

@end


#pragma mark - Preferences

@interface PreferenceParsingTests : XCTestCase
@end

@implementation PreferenceParsingTests

- (void)testPrefsOnItsOwnShowsEveryPreference
{
    EZCommandRequest request = ParsedOK({"prefs"});
    XCTAssertEqual(request.kind, EZCommandPrefs);
    XCTAssertTrue(request.prefName.empty());
}

- (void)testSettingAFlag
{
    EZCommandRequest off = ParsedOK({"prefs", "set", "show-standard", "off"});
    XCTAssertEqual(off.prefName, std::string("show-standard"));
    XCTAssertFalse(off.prefFlag);

    XCTAssertTrue(ParsedOK({"prefs", "set", "show-standard", "on"}).prefFlag);
}

- (void)testSettingACount
{
    EZCommandRequest request = ParsedOK({"prefs", "set", "curated-count", "8"});
    XCTAssertEqual(request.prefName, std::string("curated-count"));
    XCTAssertEqual(request.prefCount, 8);
}

- (void)testACountOfZeroWouldEmptyTheMenu
{
    // The interface clamps this to 1 on read. The command line refuses instead,
    // because a caller who asked for zero should hear that it is not a choice
    // rather than find the value silently changed.
    std::string error;
    XCTAssertTrue(ParseFails({"prefs", "set", "curated-count", "0"}, &error));
}

- (void)testTheLoginItemIsAPreferenceLikeTheOthers
{
    XCTAssertTrue(ParsedOK({"prefs", "set", "launch-at-login", "yes"}).prefFlag);
}

- (void)testAnUnknownPreferenceNamesItself
{
    std::string error;
    XCTAssertTrue(ParseFails({"prefs", "set", "nonsense", "on"}, &error));
    XCTAssertNotEqual(error.find("nonsense"), std::string::npos);
}

- (void)testAValueHasToFitThePreference
{
    std::string error;
    XCTAssertTrue(ParseFails({"prefs", "set", "show-standard", "maybe"}, &error));
    XCTAssertTrue(ParseFails({"prefs", "set", "curated-count", "lots"}, &error));
    XCTAssertTrue(ParseFails({"prefs", "set", "curated-count", "on"}, &error));
}

- (void)testSetNeedsBothANameAndAValue
{
    std::string error;
    XCTAssertTrue(ParseFails({"prefs", "set"}, &error));
    XCTAssertTrue(ParseFails({"prefs", "set", "show-standard"}, &error));
    XCTAssertTrue(ParseFails({"prefs", "set", "show-standard", "on", "extra"}, &error));
}

- (void)testTheOnlyActionIsSet
{
    std::string error;
    XCTAssertTrue(ParseFails({"prefs", "show-standard"}, &error));
    XCTAssertTrue(ParseFails({"prefs", "get", "show-standard"}, &error));
}

- (void)testEveryPreferenceInTheTableCanBeSet
{
    // The table drives both the listing and the parser, so a preference added
    // to it without a value shape the parser understands would fail only when
    // someone tried to set it.
    for (const EZPreferenceInfo &preference : EZPreferences()) {
        const std::string value = preference.type == EZPreferenceCount ? "3" : "on";
        EZCommandRequest request = ParsedOK({"prefs", "set", preference.name, value});
        XCTAssertEqual(request.prefName, preference.name);
    }
}

- (void)testLookupFindsWhatTheTableHoldsAndNothingElse
{
    XCTAssertTrue(EZFindPreference("curated-count") != NULL);
    XCTAssertEqual(EZFindPreference("curated-count")->type, EZPreferenceCount);
    XCTAssertTrue(EZFindPreference("launch-at-login") != NULL);
    XCTAssertEqual(EZFindPreference("launch-at-login")->type, EZPreferenceLoginItem);
    XCTAssertTrue(EZFindPreference("") == NULL);
    XCTAssertTrue(EZFindPreference("curated_count") == NULL);
}

@end


#pragma mark - Truth values

@interface BooleanParsingTests : XCTestCase
@end

@implementation BooleanParsingTests

- (void)testEverySpellingAShellUserReachesFor
{
    for (const std::string &yes : {"on", "true", "yes", "1", "ON", "True", "YES"}) {
        bool value = false;
        XCTAssertTrue(EZParseBool(yes, &value), @"%s", yes.c_str());
        XCTAssertTrue(value, @"%s", yes.c_str());
    }

    for (const std::string &no : {"off", "false", "no", "0", "OFF", "False", "No"}) {
        bool value = true;
        XCTAssertTrue(EZParseBool(no, &value), @"%s", no.c_str());
        XCTAssertFalse(value, @"%s", no.c_str());
    }
}

- (void)testAnythingElseIsRefusedRatherThanReadAsFalse
{
    bool value = false;
    XCTAssertFalse(EZParseBool("maybe", &value));
    XCTAssertFalse(EZParseBool("", &value));
    XCTAssertFalse(EZParseBool("2", &value));
    XCTAssertFalse(EZParseBool("y", &value));
}

@end


#pragma mark - JSON output

@interface JSONStringTests : XCTestCase
@end

@implementation JSONStringTests

- (void)testAPlainStringIsJustQuoted
{
    XCTAssertEqual(EZJSONString("PHL 34M2C8600"), std::string("\"PHL 34M2C8600\""));
    XCTAssertEqual(EZJSONString(""), std::string("\"\""));
}

- (void)testTheTwoCharactersThatWouldEndOrEscapeTheString
{
    XCTAssertEqual(EZJSONString("a\"b"), std::string("\"a\\\"b\""));
    XCTAssertEqual(EZJSONString("a\\b"), std::string("\"a\\\\b\""));
}

- (void)testTheWhitespaceEscapesJSONNames
{
    XCTAssertEqual(EZJSONString("a\nb"), std::string("\"a\\nb\""));
    XCTAssertEqual(EZJSONString("a\tb"), std::string("\"a\\tb\""));
    XCTAssertEqual(EZJSONString("a\rb"), std::string("\"a\\rb\""));
}

- (void)testAnyOtherControlCharacterBecomesAUnicodeEscape
{
    // A display name is whatever the monitor's EDID says, so it can carry a
    // byte that no JSON parser accepts raw.
    XCTAssertEqual(EZJSONString(std::string("a\x01" "b")), std::string("\"a\\u0001b\""));
    XCTAssertEqual(EZJSONString(std::string("\x1f")), std::string("\"\\u001f\""));
}

@end


#pragma mark - Machine-readable output

@interface JSONFlagTests : XCTestCase
@end

@implementation JSONFlagTests

- (void)testTheListingCommandsAllTakeIt
{
    XCTAssertTrue(ParsedOK({"list", "--json"}).json);
    XCTAssertTrue(ParsedOK({"modes", "--json"}).json);
    XCTAssertTrue(ParsedOK({"color", "list", "--json"}).json);
    XCTAssertTrue(ParsedOK({"custom", "list", "--json"}).json);
    XCTAssertTrue(ParsedOK({"prefs", "--json"}).json);
}

- (void)testACommandThatChangesSomethingDoesNot
{
    // There is no listing to render, so accepting the flag would promise
    // structured output that never arrives.
    std::string error;
    XCTAssertTrue(ParseFails({"set", "--width", "1920", "--json"}, &error));
    XCTAssertTrue(ParseFails({"hdr", "on", "--json"}, &error));
    XCTAssertTrue(ParseFails({"mirror", "off", "--json"}, &error));
    XCTAssertTrue(ParseFails({"restore", "--all", "--json"}, &error));
}

- (void)testTheTwoCommandsThatBothListAndChangeRefuseItOnlyWhenTheyChange
{
    // `color` and `custom` are one command each, so the flag cannot be settled
    // by the command word alone: `color list --json` prints a listing and
    // `color set 5 --json` changes the mode and has nothing to print.
    std::string error;
    XCTAssertTrue(ParseFails({"color", "set", "5", "--json"}, &error));
    XCTAssertTrue(ParseFails({"custom", "add", "--width", "1920",
                              "--height", "1080", "--json"}, &error));
    XCTAssertTrue(ParseFails({"custom", "remove", "--width", "1920",
                              "--height", "1080", "--json"}, &error));
}

- (void)testTheFlagTakesNoValue
{
    std::string error;
    XCTAssertTrue(ParseFails({"list", "--json=yes"}, &error));
}

@end


@interface JSONObjectTests : XCTestCase
@end

@implementation JSONObjectTests

- (void)testAnObjectWithNoFields
{
    XCTAssertEqual(EZJSONObject().text(), std::string("{}"));
}

- (void)testFieldsComeOutInTheOrderTheyWereAdded
{
    EZJSONObject object;
    object.addInt("index", 1);
    object.addString("name", "PHL");

    XCTAssertEqual(object.text(), std::string("{\"index\":1,\"name\":\"PHL\"}"));
}

- (void)testAStringValueIsEscaped
{
    EZJSONObject object;
    object.addString("name", "a\"b");

    XCTAssertEqual(object.text(), std::string("{\"name\":\"a\\\"b\"}"));
}

- (void)testATruthValueIsAJSONBooleanRatherThanANumber
{
    EZJSONObject object;
    object.addBool("hdr", true);
    object.addBool("mirrored", false);

    XCTAssertEqual(object.text(), std::string("{\"hdr\":true,\"mirrored\":false}"));
}

- (void)testAScaleKeepsItsFractionAndLosesItsTrailingZero
{
    // 2.0 is the common case and reads badly as 2.000000, which is what the
    // obvious format string gives.
    EZJSONObject object;
    object.addNumber("scale", 2.0);
    object.addNumber("half", 1.5);

    XCTAssertEqual(object.text(), std::string("{\"scale\":2,\"half\":1.5}"));
}

- (void)testAnArrayOfObjects
{
    XCTAssertEqual(EZJSONArray({}), std::string("[]"));
    XCTAssertEqual(EZJSONArray({"{}", "{\"a\":1}"}), std::string("[{},{\"a\":1}]"));
}

@end
