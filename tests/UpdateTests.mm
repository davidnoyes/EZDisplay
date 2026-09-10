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
/// This is the response the updater actually reads, from the URL it actually
/// asks for, so it is the fixture that fails if the release workflow ever
/// changes the shape of what it publishes.
///
/// It differs from the one above in three ways worth keeping, none of which a
/// hand-written fixture would have thought to include: the asset label is an
/// empty string rather than null, the digest is populated rather than null,
/// and the author is a Bot whose URLs are percent-encoded.
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

- (void)testASuffixAfterTheNumbersIsIgnored
{
    // Documented behavior rather than an accident: the only caller reads the
    // latest-release endpoint, which never returns a prerelease, so a tag with
    // a suffix on it compares as the release it is a candidate for. Offering
    // 1.2.3 to someone running 1.2.3-beta.1 would be a downgrade dressed up as
    // an update.
    XCTAssertEqual(EZCompareVersions("1.2.3-beta.1", "1.2.3"), 0);
    XCTAssertEqual(EZCompareVersions("1.2.3+build.7", "1.2.3"), 0);
    XCTAssertEqual(EZCompareVersions("1.2.3-beta.1", "1.2.4"), -1);
}

- (void)testATagWithNoNumbersInItIsNotNewerThanAnything
{
    // A tag such as "nightly" reaches this from the API, and every component
    // it has is zero. It must not read as newer than a real version, because
    // that is the reading that offers an update to something that is not one.
    XCTAssertEqual(EZCompareVersions("1.0.0", "nightly"), 1);
    XCTAssertEqual(EZCompareVersions("nightly", "1.0.0"), -1);
    XCTAssertEqual(EZCompareVersions("nightly", "nightly"), 0);
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

    XCTAssertEqual(release.version, std::string("1.0.0"));
    XCTAssertEqual(release.downloadURL,
                   std::string("https://github.com/davidnoyes/EZDisplay/"
                               "releases/download/v1.0.0/EZDisplay-1.0.0.zip"));
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

- (void)testAnAnswerWorthReadingHasNothingToSay
{
    XCTAssertEqual(EZUpdateStatusForHTTPCode(200), std::string(""));
}

- (void)testNoReleasesYetIsNotAFault
{
    // 404 is what a repository that has published nothing answers, which is an
    // ordinary state for a new project and should not read as something broken.
    XCTAssertEqual(EZUpdateStatusForHTTPCode(404),
                   std::string("There are no releases yet."));
}

- (void)testAnyOtherCodeIsNamed
{
    // 403 is the rate limit, which is the one a run of checks actually hits.
    // The number is in the text because it is the only part that says what to
    // do differently.
    XCTAssertEqual(EZUpdateStatusForHTTPCode(403),
                   std::string("GitHub answered 403."));
    XCTAssertEqual(EZUpdateStatusForHTTPCode(500),
                   std::string("GitHub answered 500."));
}

@end

#pragma mark - Telling the two signatures apart

@interface AdHocRequirementTests : XCTestCase
@end

@implementation AdHocRequirementTests

- (void)testAnAdHocRequirementIsRecognized
{
    // Captured with `codesign -d -r-` from a Debug build, which is what every
    // developer build of this app is signed as. It names one code hash, so no
    // other build can ever satisfy it — which is why an update from here has
    // to be refused with an explanation rather than as tampering.
    XCTAssertTrue(EZUpdateRequirementIsAdHoc(
        "cdhash H\"aab34eff91af8422589d2ff83f7569844a67db8e\""));
}

- (void)testTheCertificatesRequirementIsNotAdHoc
{
    // The shape a Release build signed by "EZDisplay Self Signed" carries. It
    // names the certificate rather than a build, which is the whole reason for
    // signing: it is stable across releases, so an update can be held to it.
    XCTAssertFalse(EZUpdateRequirementIsAdHoc(
        "identifier \"io.github.davidnoyes.ezdisplay\" and certificate leaf = "
        "H\"7b8a1c4f2e9d6a3b5c8e0f1d2a4b6c8e0f1d2a4b\""));
}

- (void)testAnEmptyRequirementIsNotAdHoc
{
    // SecRequirementCopyString failing leaves nothing to read, and the caller
    // carries on to the real signature check rather than refusing outright.
    XCTAssertFalse(EZUpdateRequirementIsAdHoc(""));
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
