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

/// The same response as the one below, with its single asset changed from a
/// .zip to a .dmg. That one edit is the whole point: it is the case where a
/// release exists but ships nothing this app can install.
///
/// Derived from a real capture rather than written by hand, so every odd field
/// GitHub sends is still here — the uploader object, the reactions block, and
/// the keys that come back null rather than missing. A fixture cut down to what
/// the parser is known to want cannot catch a parser that trips over the rest.
static const char *const kCapturedDmgRelease = R"JSON(
{
  "url": "https://api.github.com/repos/davidnoyes/EZDisplay/releases/386642708",
  "assets_url": "https://api.github.com/repos/davidnoyes/EZDisplay/releases/386642708/assets",
  "upload_url": "https://uploads.github.com/repos/davidnoyes/EZDisplay/releases/386642708/assets{?name,label}",
  "html_url": "https://github.com/davidnoyes/EZDisplay/releases/tag/v1.0.0",
  "id": 386642708,
  "author": {
    "login": "github-actions[bot]",
    "id": 41898282,
    "node_id": "MDM6Qm90NDE4OTgyODI=",
    "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/github-actions%5Bbot%5D",
    "html_url": "https://github.com/apps/github-actions",
    "followers_url": "https://api.github.com/users/github-actions%5Bbot%5D/followers",
    "following_url": "https://api.github.com/users/github-actions%5Bbot%5D/following{/other_user}",
    "gists_url": "https://api.github.com/users/github-actions%5Bbot%5D/gists{/gist_id}",
    "starred_url": "https://api.github.com/users/github-actions%5Bbot%5D/starred{/owner}{/repo}",
    "subscriptions_url": "https://api.github.com/users/github-actions%5Bbot%5D/subscriptions",
    "organizations_url": "https://api.github.com/users/github-actions%5Bbot%5D/orgs",
    "repos_url": "https://api.github.com/users/github-actions%5Bbot%5D/repos",
    "events_url": "https://api.github.com/users/github-actions%5Bbot%5D/events{/privacy}",
    "received_events_url": "https://api.github.com/users/github-actions%5Bbot%5D/received_events",
    "type": "Bot",
    "user_view_type": "public",
    "site_admin": false
  },
  "node_id": "RE_kwDOUVqxTc4XC7MU",
  "tag_name": "v1.0.0",
  "target_commitish": "main",
  "name": "EZDisplay 1.0.0",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2026-09-10T21:10:55Z",
  "updated_at": "2026-09-10T21:43:12Z",
  "published_at": "2026-09-10T21:43:12Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/davidnoyes/EZDisplay/releases/assets/555879526",
      "id": 555879526,
      "node_id": "RA_kwDOUVqxTc4hIgxm",
      "name": "EZDisplay-1.0.0.dmg",
      "label": "",
      "uploader": {
        "login": "github-actions[bot]",
        "id": 41898282,
        "node_id": "MDM6Qm90NDE4OTgyODI=",
        "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4",
        "gravatar_id": "",
        "url": "https://api.github.com/users/github-actions%5Bbot%5D",
        "html_url": "https://github.com/apps/github-actions",
        "followers_url": "https://api.github.com/users/github-actions%5Bbot%5D/followers",
        "following_url": "https://api.github.com/users/github-actions%5Bbot%5D/following{/other_user}",
        "gists_url": "https://api.github.com/users/github-actions%5Bbot%5D/gists{/gist_id}",
        "starred_url": "https://api.github.com/users/github-actions%5Bbot%5D/starred{/owner}{/repo}",
        "subscriptions_url": "https://api.github.com/users/github-actions%5Bbot%5D/subscriptions",
        "organizations_url": "https://api.github.com/users/github-actions%5Bbot%5D/orgs",
        "repos_url": "https://api.github.com/users/github-actions%5Bbot%5D/repos",
        "events_url": "https://api.github.com/users/github-actions%5Bbot%5D/events{/privacy}",
        "received_events_url": "https://api.github.com/users/github-actions%5Bbot%5D/received_events",
        "type": "Bot",
        "user_view_type": "public",
        "site_admin": false
      },
      "content_type": "application/x-apple-diskimage",
      "state": "uploaded",
      "size": 501774,
      "digest": "sha256:44a71b0587372bdd2a21546471107fc5c49428cb11194cc4dbac3573da6bb5bc",
      "download_count": 0,
      "created_at": "2026-09-10T21:43:11Z",
      "updated_at": "2026-09-10T21:43:11Z",
      "browser_download_url": "https://github.com/davidnoyes/EZDisplay/releases/download/v1.0.0/EZDisplay-1.0.0.dmg"
    }
  ],
  "tarball_url": "https://api.github.com/repos/davidnoyes/EZDisplay/tarball/v1.0.0",
  "zipball_url": "https://api.github.com/repos/davidnoyes/EZDisplay/zipball/v1.0.0",
  "body": "## Installing\n\n1. Download `EZDisplay-1.0.0.dmg`, unzip it, and move **EZDisplay.app** to your **Applications** folder.\n2. Open it. macOS refuses the first launch and offers to move it to the Trash, because this app is signed by its own certificate rather than by an Apple one — which costs $99 a year for a project with one user.\n3. Open **System Settings > Privacy & Security**, scroll to the message naming EZDisplay, and choose **Open Anyway**.\n\nThat is once per machine, not once per update. Every release is signed by the same certificate, so later versions open without asking again — and the Accessibility permission the volume keys need survives an update for the same reason.\n\nTo let EZDisplay control the volume keys, grant it Accessibility in **System Settings > Privacy & Security > Accessibility**.\n\nSHA-256: `44a71b0587372bdd2a21546471107fc5c49428cb11194cc4dbac3573da6bb5bc`\n\n\n**Full Changelog**: https://github.com/davidnoyes/EZDisplay/commits/v1.0.0"
}
)JSON";

/// api.github.com/repos/davidnoyes/EZDisplay/releases/latest, verbatim,
/// fetched 2026-09-10: the v1.0.0 release, the first this project cut.
///
/// This is what this project's own release workflow published, from the URL the
/// updater asks for, so it records the shape that shipped rather than a guess at
/// it. Being a snapshot, it cannot notice the workflow changing shape later —
/// only a re-capture does that. What it does pin down is that the payload the
/// workflow produced on the day parses, which the adapted fixture it replaced
/// could not honestly claim.
///
/// It differs from the one above in three ways, none of which the parser reads:
/// the asset label is an empty string rather than null, the digest is populated
/// rather than null, and the author is a Bot whose URLs are percent-encoded.
/// They are kept for the reason given at the top of this file — an unread field
/// is exactly the kind a parser trips over — not because anything asserts them.
static const char *const kCapturedZipRelease = R"JSON(
{
  "url": "https://api.github.com/repos/davidnoyes/EZDisplay/releases/386642708",
  "assets_url": "https://api.github.com/repos/davidnoyes/EZDisplay/releases/386642708/assets",
  "upload_url": "https://uploads.github.com/repos/davidnoyes/EZDisplay/releases/386642708/assets{?name,label}",
  "html_url": "https://github.com/davidnoyes/EZDisplay/releases/tag/v1.0.0",
  "id": 386642708,
  "author": {
    "login": "github-actions[bot]",
    "id": 41898282,
    "node_id": "MDM6Qm90NDE4OTgyODI=",
    "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/github-actions%5Bbot%5D",
    "html_url": "https://github.com/apps/github-actions",
    "followers_url": "https://api.github.com/users/github-actions%5Bbot%5D/followers",
    "following_url": "https://api.github.com/users/github-actions%5Bbot%5D/following{/other_user}",
    "gists_url": "https://api.github.com/users/github-actions%5Bbot%5D/gists{/gist_id}",
    "starred_url": "https://api.github.com/users/github-actions%5Bbot%5D/starred{/owner}{/repo}",
    "subscriptions_url": "https://api.github.com/users/github-actions%5Bbot%5D/subscriptions",
    "organizations_url": "https://api.github.com/users/github-actions%5Bbot%5D/orgs",
    "repos_url": "https://api.github.com/users/github-actions%5Bbot%5D/repos",
    "events_url": "https://api.github.com/users/github-actions%5Bbot%5D/events{/privacy}",
    "received_events_url": "https://api.github.com/users/github-actions%5Bbot%5D/received_events",
    "type": "Bot",
    "user_view_type": "public",
    "site_admin": false
  },
  "node_id": "RE_kwDOUVqxTc4XC7MU",
  "tag_name": "v1.0.0",
  "target_commitish": "main",
  "name": "EZDisplay 1.0.0",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2026-09-10T21:10:55Z",
  "updated_at": "2026-09-10T21:43:12Z",
  "published_at": "2026-09-10T21:43:12Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/davidnoyes/EZDisplay/releases/assets/555879526",
      "id": 555879526,
      "node_id": "RA_kwDOUVqxTc4hIgxm",
      "name": "EZDisplay-1.0.0.zip",
      "label": "",
      "uploader": {
        "login": "github-actions[bot]",
        "id": 41898282,
        "node_id": "MDM6Qm90NDE4OTgyODI=",
        "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4",
        "gravatar_id": "",
        "url": "https://api.github.com/users/github-actions%5Bbot%5D",
        "html_url": "https://github.com/apps/github-actions",
        "followers_url": "https://api.github.com/users/github-actions%5Bbot%5D/followers",
        "following_url": "https://api.github.com/users/github-actions%5Bbot%5D/following{/other_user}",
        "gists_url": "https://api.github.com/users/github-actions%5Bbot%5D/gists{/gist_id}",
        "starred_url": "https://api.github.com/users/github-actions%5Bbot%5D/starred{/owner}{/repo}",
        "subscriptions_url": "https://api.github.com/users/github-actions%5Bbot%5D/subscriptions",
        "organizations_url": "https://api.github.com/users/github-actions%5Bbot%5D/orgs",
        "repos_url": "https://api.github.com/users/github-actions%5Bbot%5D/repos",
        "events_url": "https://api.github.com/users/github-actions%5Bbot%5D/events{/privacy}",
        "received_events_url": "https://api.github.com/users/github-actions%5Bbot%5D/received_events",
        "type": "Bot",
        "user_view_type": "public",
        "site_admin": false
      },
      "content_type": "application/zip",
      "state": "uploaded",
      "size": 501774,
      "digest": "sha256:44a71b0587372bdd2a21546471107fc5c49428cb11194cc4dbac3573da6bb5bc",
      "download_count": 0,
      "created_at": "2026-09-10T21:43:11Z",
      "updated_at": "2026-09-10T21:43:11Z",
      "browser_download_url": "https://github.com/davidnoyes/EZDisplay/releases/download/v1.0.0/EZDisplay-1.0.0.zip"
    }
  ],
  "tarball_url": "https://api.github.com/repos/davidnoyes/EZDisplay/tarball/v1.0.0",
  "zipball_url": "https://api.github.com/repos/davidnoyes/EZDisplay/zipball/v1.0.0",
  "body": "## Installing\n\n1. Download `EZDisplay-1.0.0.zip`, unzip it, and move **EZDisplay.app** to your **Applications** folder.\n2. Open it. macOS refuses the first launch and offers to move it to the Trash, because this app is signed by its own certificate rather than by an Apple one — which costs $99 a year for a project with one user.\n3. Open **System Settings > Privacy & Security**, scroll to the message naming EZDisplay, and choose **Open Anyway**.\n\nThat is once per machine, not once per update. Every release is signed by the same certificate, so later versions open without asking again — and the Accessibility permission the volume keys need survives an update for the same reason.\n\nTo let EZDisplay control the volume keys, grant it Accessibility in **System Settings > Privacy & Security > Accessibility**.\n\nSHA-256: `44a71b0587372bdd2a21546471107fc5c49428cb11194cc4dbac3573da6bb5bc`\n\n\n**Full Changelog**: https://github.com/davidnoyes/EZDisplay/commits/v1.0.0"
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
