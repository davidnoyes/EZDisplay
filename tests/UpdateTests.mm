//
//  UpdateTests.mm
//  EZDisplay
//
//  Tests for the decisions in src/Update.h: which release is newer, what
//  GitHub's answer describes, and what the About box says about it.
//
//  The two responses below are captured, not written. GitHub's release payload
//  carries far more than an updater reads — a whole uploader object, a
//  reactions block, and fields that are null in practice rather than absent —
//  and a fixture cut down to what the parser is known to want cannot catch a
//  parser that trips over the rest.
//

#import <XCTest/XCTest.h>
#import "Update.h"

#include <string>

#pragma mark - Captured responses

/// api.github.com/repos/MonitorControl/MonitorControl/releases/latest, verbatim,
/// fetched 2026-09-10.
///
/// Another project's release, kept because it is untouched: it proves the
/// parser survives the whole of what GitHub sends. It ships a .dmg rather than
/// a .zip, which makes it the case where there is nothing to download.
static const char *const kCapturedDmgRelease = R"JSON(
{
  "url": "https://api.github.com/repos/MonitorControl/MonitorControl/releases/178383625",
  "assets_url": "https://api.github.com/repos/MonitorControl/MonitorControl/releases/178383625/assets",
  "upload_url": "https://uploads.github.com/repos/MonitorControl/MonitorControl/releases/178383625/assets{?name,label}",
  "html_url": "https://github.com/MonitorControl/MonitorControl/releases/tag/v4.3.3",
  "id": 178383625,
  "author": {
    "login": "waydabber",
    "id": 37590873,
    "node_id": "MDQ6VXNlcjM3NTkwODcz",
    "avatar_url": "https://avatars.githubusercontent.com/u/37590873?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/waydabber",
    "html_url": "https://github.com/waydabber",
    "followers_url": "https://api.github.com/users/waydabber/followers",
    "following_url": "https://api.github.com/users/waydabber/following{/other_user}",
    "gists_url": "https://api.github.com/users/waydabber/gists{/gist_id}",
    "starred_url": "https://api.github.com/users/waydabber/starred{/owner}{/repo}",
    "subscriptions_url": "https://api.github.com/users/waydabber/subscriptions",
    "organizations_url": "https://api.github.com/users/waydabber/orgs",
    "repos_url": "https://api.github.com/users/waydabber/repos",
    "events_url": "https://api.github.com/users/waydabber/events{/privacy}",
    "received_events_url": "https://api.github.com/users/waydabber/received_events",
    "type": "User",
    "user_view_type": "public",
    "site_admin": false
  },
  "node_id": "RE_kwDOBi-ezs4KoesJ",
  "tag_name": "v4.3.3",
  "target_commitish": "main",
  "name": "MonitorControl v4.3.3",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2024-10-04T10:51:10Z",
  "updated_at": "2024-10-10T15:38:59Z",
  "published_at": "2024-10-04T10:56:14Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/MonitorControl/MonitorControl/releases/assets/196854903",
      "id": 196854903,
      "node_id": "RA_kwDOBi-ezs4Lu8R3",
      "name": "MonitorControl.4.3.3.dmg",
      "label": null,
      "uploader": {
        "login": "waydabber",
        "id": 37590873,
        "node_id": "MDQ6VXNlcjM3NTkwODcz",
        "avatar_url": "https://avatars.githubusercontent.com/u/37590873?v=4",
        "gravatar_id": "",
        "url": "https://api.github.com/users/waydabber",
        "html_url": "https://github.com/waydabber",
        "followers_url": "https://api.github.com/users/waydabber/followers",
        "following_url": "https://api.github.com/users/waydabber/following{/other_user}",
        "gists_url": "https://api.github.com/users/waydabber/gists{/gist_id}",
        "starred_url": "https://api.github.com/users/waydabber/starred{/owner}{/repo}",
        "subscriptions_url": "https://api.github.com/users/waydabber/subscriptions",
        "organizations_url": "https://api.github.com/users/waydabber/orgs",
        "repos_url": "https://api.github.com/users/waydabber/repos",
        "events_url": "https://api.github.com/users/waydabber/events{/privacy}",
        "received_events_url": "https://api.github.com/users/waydabber/received_events",
        "type": "User",
        "user_view_type": "public",
        "site_admin": false
      },
      "content_type": "application/x-diskcopy",
      "state": "uploaded",
      "size": 20788084,
      "digest": null,
      "download_count": 556456,
      "created_at": "2024-10-04T10:55:57Z",
      "updated_at": "2024-10-04T10:56:00Z",
      "browser_download_url": "https://github.com/MonitorControl/MonitorControl/releases/download/v4.3.3/MonitorControl.4.3.3.dmg"
    }
  ],
  "tarball_url": "https://api.github.com/repos/MonitorControl/MonitorControl/tarball/v4.3.3",
  "zipball_url": "https://api.github.com/repos/MonitorControl/MonitorControl/zipball/v4.3.3",
  "body": "This update contains some minor fixes and changes to the previous app version which introduced macOS Sequoia compatibility and included some other changes.\r\n\r\nFor more features please consider switching to **[BetterDisplay](https://betterdisplay.pro)**. \r\n\r\nPlease support this project at our **[opencollective site](https://opencollective.com/monitorcontrol/donate)** for continued development.\r\n\r\nDue to a change in app signature, if you are still running v4.2.0, auto-update will not work. You need to download and install this version manually.\r\n\r\n## What's Changed\r\n\r\n- Fixed: \"Dead pixel(s)\" at the left bottom of the external screen appears when app is running - @waydabber\r\n- Fixed: App menu in the menu bar is showing icons when text is selected \u2014 and vice versa - @waydabber\r\n- Fixed: Menu Bar Panel overflowing in Spanish - @waydabber\r\n- Renamed all occurenses of `Preferences` to `Settings` + update to the latest version of [sindresorhus/Settings ](https://github.com/sindresorhus/Settings)- @waydabber\r\n",
  "discussion_url": "https://github.com/MonitorControl/MonitorControl/discussions/1647",
  "reactions": {
    "url": "https://api.github.com/repos/MonitorControl/MonitorControl/releases/178383625/reactions",
    "total_count": 480,
    "+1": 209,
    "-1": 0,
    "laugh": 27,
    "hooray": 59,
    "confused": 0,
    "heart": 117,
    "rocket": 68,
    "eyes": 0
  },
  "mentions_count": 1
}
)JSON";

/// The same response with this project's values in place of that one's: the
/// repository, the tag, and an asset named the way EZDisplay's release
/// workflow names one. Every key, and every other value, is as GitHub sent it.
///
/// Adapted rather than captured because EZDisplay has no release yet. When it
/// has one, this should be replaced with the real thing.
static const char *const kCapturedZipRelease = R"JSON(
{
  "url": "https://api.github.com/repos/davidnoyes/ezdisplay/releases/178383625",
  "assets_url": "https://api.github.com/repos/davidnoyes/ezdisplay/releases/178383625/assets",
  "upload_url": "https://uploads.github.com/repos/davidnoyes/ezdisplay/releases/178383625/assets{?name,label}",
  "html_url": "https://github.com/davidnoyes/ezdisplay/releases/tag/v1.1.0",
  "id": 178383625,
  "author": {
    "login": "waydabber",
    "id": 37590873,
    "node_id": "MDQ6VXNlcjM3NTkwODcz",
    "avatar_url": "https://avatars.githubusercontent.com/u/37590873?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/waydabber",
    "html_url": "https://github.com/waydabber",
    "followers_url": "https://api.github.com/users/waydabber/followers",
    "following_url": "https://api.github.com/users/waydabber/following{/other_user}",
    "gists_url": "https://api.github.com/users/waydabber/gists{/gist_id}",
    "starred_url": "https://api.github.com/users/waydabber/starred{/owner}{/repo}",
    "subscriptions_url": "https://api.github.com/users/waydabber/subscriptions",
    "organizations_url": "https://api.github.com/users/waydabber/orgs",
    "repos_url": "https://api.github.com/users/waydabber/repos",
    "events_url": "https://api.github.com/users/waydabber/events{/privacy}",
    "received_events_url": "https://api.github.com/users/waydabber/received_events",
    "type": "User",
    "user_view_type": "public",
    "site_admin": false
  },
  "node_id": "RE_kwDOBi-ezs4KoesJ",
  "tag_name": "v1.1.0",
  "target_commitish": "main",
  "name": "EZDisplay 1.1.0",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2024-10-04T10:51:10Z",
  "updated_at": "2024-10-10T15:38:59Z",
  "published_at": "2024-10-04T10:56:14Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/davidnoyes/ezdisplay/releases/assets/196854903",
      "id": 196854903,
      "node_id": "RA_kwDOBi-ezs4Lu8R3",
      "name": "EZDisplay-1.1.0.zip",
      "label": null,
      "uploader": {
        "login": "waydabber",
        "id": 37590873,
        "node_id": "MDQ6VXNlcjM3NTkwODcz",
        "avatar_url": "https://avatars.githubusercontent.com/u/37590873?v=4",
        "gravatar_id": "",
        "url": "https://api.github.com/users/waydabber",
        "html_url": "https://github.com/waydabber",
        "followers_url": "https://api.github.com/users/waydabber/followers",
        "following_url": "https://api.github.com/users/waydabber/following{/other_user}",
        "gists_url": "https://api.github.com/users/waydabber/gists{/gist_id}",
        "starred_url": "https://api.github.com/users/waydabber/starred{/owner}{/repo}",
        "subscriptions_url": "https://api.github.com/users/waydabber/subscriptions",
        "organizations_url": "https://api.github.com/users/waydabber/orgs",
        "repos_url": "https://api.github.com/users/waydabber/repos",
        "events_url": "https://api.github.com/users/waydabber/events{/privacy}",
        "received_events_url": "https://api.github.com/users/waydabber/received_events",
        "type": "User",
        "user_view_type": "public",
        "site_admin": false
      },
      "content_type": "application/zip",
      "state": "uploaded",
      "size": 2416133,
      "digest": null,
      "download_count": 556456,
      "created_at": "2024-10-04T10:55:57Z",
      "updated_at": "2024-10-04T10:56:00Z",
      "browser_download_url": "https://github.com/davidnoyes/ezdisplay/releases/download/v1.1.0/EZDisplay-1.1.0.zip"
    }
  ],
  "tarball_url": "https://api.github.com/repos/davidnoyes/ezdisplay/tarball/v1.1.0",
  "zipball_url": "https://api.github.com/repos/davidnoyes/ezdisplay/zipball/v1.1.0",
  "body": "Adds an in-app updater.\r\n\r\n* Check for updates from the About box.\r\n",
  "discussion_url": "https://github.com/davidnoyes/ezdisplay/discussions/1647",
  "reactions": {
    "url": "https://api.github.com/repos/davidnoyes/ezdisplay/releases/178383625/reactions",
    "total_count": 480,
    "+1": 209,
    "-1": 0,
    "laugh": 27,
    "hooray": 59,
    "confused": 0,
    "heart": 117,
    "rocket": 68,
    "eyes": 0
  },
  "mentions_count": 1
}
)JSON";

#pragma mark - Comparing two releases

@interface VersionComparisonTests : XCTestCase
@end

@implementation VersionComparisonTests

- (void)testALaterPatchIsTheNewerRelease
{
    XCTAssertEqual(EZCompareVersions("1.2.3", "1.2.4"), -1);
    XCTAssertEqual(EZCompareVersions("1.2.4", "1.2.3"), 1);
}

- (void)testTenIsNewerThanNine
{
    // The reason this is compared as numbers. As text "1.10.0" sorts before
    // "1.9.0", so the tenth minor release would have looked like a downgrade
    // to everyone running the ninth.
    XCTAssertEqual(EZCompareVersions("1.9.0", "1.10.0"), -1);
    XCTAssertEqual(EZCompareVersions("1.10.0", "1.9.0"), 1);
}

- (void)testAMajorVersionOutranksEverythingBelowIt
{
    XCTAssertEqual(EZCompareVersions("1.99.99", "2.0.0"), -1);
}

- (void)testAMissingComponentCountsAsZero
{
    // A tag can be written either way, and 1.2 and 1.2.0 are one release.
    XCTAssertEqual(EZCompareVersions("1.2", "1.2.0"), 0);
    XCTAssertEqual(EZCompareVersions("1.2.0", "1.2"), 0);
    XCTAssertEqual(EZCompareVersions("1.2", "1.2.1"), -1);
}

- (void)testTheTagsLeadingLetterIsNotPartOfTheNumber
{
    // Releases are tagged v1.1.0, so the tag arrives with a letter on the
    // front. Comparing that against a bundle's plain "1.1.0" has to say equal.
    XCTAssertEqual(EZCompareVersions("v1.1.0", "1.1.0"), 0);
    XCTAssertEqual(EZCompareVersions("v1.1.0", "v1.2.0"), -1);
}

- (void)testTheSameReleaseIsNeitherNewerNorOlder
{
    XCTAssertEqual(EZCompareVersions("1.0.0", "1.0.0"), 0);
}

@end

#pragma mark - Reading GitHub's answer

@interface ReleaseParsingTests : XCTestCase
@end

@implementation ReleaseParsingTests

- (void)testTheReleaseIsReadOutOfTheResponse
{
    EZRelease release;
    std::string error;

    XCTAssertTrue(EZReleaseFromJSON(kCapturedZipRelease, &release, &error),
                  @"%s", error.c_str());

    XCTAssertEqual(release.version, std::string("1.1.0"));
    XCTAssertEqual(release.downloadURL,
                   std::string("https://github.com/davidnoyes/ezdisplay/"
                               "releases/download/v1.1.0/EZDisplay-1.1.0.zip"));
    XCTAssertTrue(release.notes.find("in-app updater") != std::string::npos,
                  @"notes were: %s", release.notes.c_str());
}

- (void)testAReleaseWithNothingToDownloadIsRefused
{
    // A release can exist with no asset this app can install — that one ships
    // a disk image. Refusing names the problem; picking the nearest thing
    // would download something that is not an app.
    EZRelease release;
    std::string error;

    XCTAssertFalse(EZReleaseFromJSON(kCapturedDmgRelease, &release, &error));
    XCTAssertFalse(error.empty());
}

- (void)testAResponseThatIsNotJSONIsRefused
{
    // What a captive network or a proxy returns instead of the API.
    EZRelease release;
    std::string error;

    XCTAssertFalse(EZReleaseFromJSON("<html>404 Not Found</html>",
                                     &release, &error));
    XCTAssertFalse(error.empty());
}

- (void)testAResponseWithNoTagIsRefused
{
    // Valid JSON, and none of what was asked for. Without a version there is
    // nothing to compare against, so there is no update to offer.
    EZRelease release;
    std::string error;

    XCTAssertFalse(EZReleaseFromJSON("{\"message\":\"Not Found\"}",
                                     &release, &error));
    XCTAssertFalse(error.empty());
}

@end

#pragma mark - What the About box says

@interface UpdateStatusTextTests : XCTestCase
@end

@implementation UpdateStatusTextTests

- (void)testAnAvailableUpdateIsNamed
{
    // The version is in the text because the answer to "what would I get?" is
    // the thing that decides whether to take it.
    std::string text = EZUpdateStatusText("1.0.0", "1.1.0");

    XCTAssertTrue(text.find("1.1.0") != std::string::npos,
                  @"status was: %s", text.c_str());
}

- (void)testTheSameVersionIsUpToDate
{
    XCTAssertEqual(EZUpdateStatusText("1.1.0", "1.1.0"),
                   std::string("EZDisplay is up to date."));
}

- (void)testABuildAheadOfTheReleaseIsNotOfferedADowngrade
{
    // The normal state of the machine this is built on. Offering 1.0.0 to a
    // 1.1.0 build would replace the work in progress with the last release.
    std::string text = EZUpdateStatusText("1.1.0", "1.0.0");

    XCTAssertTrue(text.find("1.0.0") == std::string::npos,
                  @"status offered the older release: %s", text.c_str());
}

@end

#pragma mark - Whether the running copy can be replaced

@interface BundleReplacementTests : XCTestCase
@end

@implementation BundleReplacementTests

- (void)testAnInstalledBundleCanBeReplaced
{
    std::string reason;

    XCTAssertTrue(EZUpdateCanReplaceBundle("/Applications/EZDisplay.app", &reason),
                  @"refused with: %s", reason.c_str());
}

- (void)testABundleAnywhereElseCanStillBeReplaced
{
    // Nothing says an app has to live in /Applications, and a developer's copy
    // in a build directory is the one that gets tested first.
    std::string reason;

    XCTAssertTrue(EZUpdateCanReplaceBundle(
        "/Users/someone/git/ezdisplay/DerivedData/Build/Products/Debug/EZDisplay.app",
        &reason), @"refused with: %s", reason.c_str());
}

- (void)testATranslocatedBundleIsRefused
{
    // macOS runs a quarantined app from a read-only copy at a path like this.
    // Replacing that copy succeeds and changes nothing, so the refusal has to
    // happen here rather than being discovered by the user next launch.
    std::string reason;
    bool allowed = EZUpdateCanReplaceBundle(
        "/private/var/folders/vb/x/T/AppTranslocation/8A1F-4C/d/EZDisplay.app",
        &reason);

    XCTAssertFalse(allowed);
    XCTAssertFalse(reason.empty(), @"a refusal has to say why");
}

- (void)testSomethingThatIsNotABundleIsRefused
{
    // The command line runs from the same code and has no bundle to swap.
    std::string reason;

    XCTAssertFalse(EZUpdateCanReplaceBundle("/usr/local/bin/ezdisplay", &reason));
    XCTAssertFalse(reason.empty(), @"a refusal has to say why");
}

- (void)testTheRefusalNamesWhatToDoAboutIt
{
    // A reason with no remedy in it leaves the user stuck: the fix for
    // translocation is to move the app and open it once from there.
    std::string reason;

    EZUpdateCanReplaceBundle("/private/var/folders/x/AppTranslocation/1/d/EZDisplay.app",
                             &reason);

    XCTAssertTrue(reason.find("Applications") != std::string::npos,
                  @"reason was: %s", reason.c_str());
}

@end

#pragma mark - Finding the app in an unpacked release

@interface ArchiveContentsTests : XCTestCase
@end

@implementation ArchiveContentsTests

- (void)testTheOnlyBundleIsTheApp
{
    XCTAssertEqual(EZUpdateAppInArchive({"EZDisplay.app"}),
                   std::string("EZDisplay.app"));
}

- (void)testTheSidecarsMacOSAddsAreIgnored
{
    // What `zip -r` on a Mac actually produces, and what ditto leaves behind
    // when it unpacks it.
    std::vector<std::string> entries = {"__MACOSX", ".DS_Store", "EZDisplay.app"};

    XCTAssertEqual(EZUpdateAppInArchive(entries), std::string("EZDisplay.app"));
}

- (void)testAnArchiveWithNoAppIsRefused
{
    XCTAssertEqual(EZUpdateAppInArchive({"README.md", "LICENSE"}),
                   std::string(""));
}

- (void)testAnArchiveWithTwoAppsIsRefused
{
    // Guessing which one to install is guessing what gets run afterwards.
    std::vector<std::string> entries = {"EZDisplay.app", "Something Else.app"};

    XCTAssertEqual(EZUpdateAppInArchive(entries), std::string(""));
}

- (void)testAnEmptyArchiveIsRefused
{
    XCTAssertEqual(EZUpdateAppInArchive({}), std::string(""));
}

@end
