//
//  Update.h
//  EZDisplay
//
//  The decisions an update makes before anything is downloaded: which of two
//  releases is newer, what GitHub's answer describes, and what the About box
//  says about where this build stands.
//
//  Pure functions over plain values, for the same reason CommandPlan.h is: the
//  fetching, unpacking, and replacing cannot be exercised by a test, but none
//  of the choices need to touch the network to be made. Those are all here.
//

#pragma once

#import <Foundation/Foundation.h>

// The decisions are C++ and the facade below is Objective-C, and this header is
// read from both sides: the tests and Update.mm compile as Objective-C++, while
// the Swift bridging header compiles as plain Objective-C and would not know
// what std::string is. So the C++ half is behind the guard and the facade is
// not, which is what makes one header serve both.
#ifdef __cplusplus

#include <string>
#include <vector>

/// How two releases compare: -1 when `a` is the older, 1 when `a` is the newer,
/// 0 when they are the same release.
///
/// Compared as numbers per component rather than as text, because 1.10.0 sorts
/// before 1.9.0 as text and that would offer everyone a downgrade the first
/// time a minor version reached ten. A leading "v" is ignored, so a git tag can
/// be handed over as it comes. A missing component counts as zero, so 1.2 and
/// 1.2.0 are the same release.
///
/// Anything after the numbers is ignored, so 1.2.3-beta.1 and 1.2.3 compare
/// equal. That is not semantic versioning, and it does not need to be: the only
/// caller reads GitHub's latest-release endpoint, which never returns a
/// prerelease.
int EZCompareVersions(const std::string &a, const std::string &b);

/// A release, as much of one as an update needs.
struct EZRelease {
    std::string version;      // The tag with any leading "v" removed.
    std::string downloadURL;
    std::string notes;
};

/// The release described by GitHub's latest-release response.
///
/// Fails, with a reason, on anything it cannot read: an update that installs
/// the wrong thing is worse than one that does not happen, and the reason is
/// the only thing the About box can show when it does not.
///
/// Both out-parameters are required. Marked so rather than left to the reader,
/// because the Objective-C half of this header puts the file under nullability
/// audit and every pointer in it has to say which it is.
bool EZReleaseFromJSON(const std::string &json, EZRelease *_Nonnull release,
                       std::string *_Nonnull error);

/// What the About box says about this build against the latest release.
///
/// Takes both rather than reading either, so a test can check the wording
/// without the answer depending on which bundle happened to run it.
std::string EZUpdateStatusText(const std::string &current,
                               const std::string &latest);

/// Whether an update is allowed to replace the bundle running from this path,
/// and a sentence saying why not when it is not.
///
/// Two cases have to be caught before anything is downloaded. A bundle macOS
/// has translocated is running from a read-only copy that disappears when it
/// quits, so replacing it would appear to work and change nothing. And a path
/// that is not a bundle at all is the command line, or a test host, neither of
/// which can be updated in place.
bool EZUpdateCanReplaceBundle(const std::string &bundlePath,
                              std::string *_Nonnull reason);

/// The one application bundle among the names an unpacked release left behind,
/// or nothing when there is not exactly one.
///
/// Archives made on macOS carry a __MACOSX sidecar and often a .DS_Store, so
/// "the only entry" is not the same as "the only app". Anything but a single
/// candidate is refused rather than guessed at, because the guess would be what
/// gets installed.
std::string EZUpdateAppInArchive(const std::vector<std::string> &entries);

#endif  // __cplusplus

NS_ASSUME_NONNULL_BEGIN

/// The answer to one check, in the form the About box needs it.
///
/// One object rather than several callback arguments, because every one of them
/// is absent in some outcome — a network failure has a message and no version, a
/// current build has a version and nothing to offer — and a shape that says so
/// is better than four parameters that are sometimes nil.
@interface EZUpdateCheck : NSObject
/// A sentence to show, whatever happened. Never nil, including on failure.
@property (readonly, copy) NSString *status;
/// The latest release, when GitHub answered. Nil when it did not.
@property (readonly, copy, nullable) NSString *version;
@property (readonly, copy, nullable) NSString *downloadURL;
/// Whether that release is newer than this build. The one thing that decides
/// whether there is anything to offer, so it is computed once, here.
@property (readonly) BOOL updateAvailable;
@end

@interface EZUpdater : NSObject

/// CFBundleShortVersionString and CFBundleVersion of the running bundle: the
/// marketing version and the build number Xcode wrote into it.
+ (NSString *)currentVersion;
+ (NSString *)currentBuild;

/// Asks GitHub for the latest release and calls back on the main thread.
///
/// Every failure arrives as a check with a `status` to show rather than as an
/// error to handle: an update check that cannot reach the network is an
/// ordinary thing to happen to a menu-bar app, and the only useful response is
/// to say so in the panel the user is already looking at.
+ (void)checkWithCompletion:(void (^)(EZUpdateCheck *check))completion;

/// Downloads a release, proves it is this app signed by the same key, and puts
/// it where the running copy is.
///
/// The proof is the point. A self-signed certificate means nothing to
/// Gatekeeper, so no part of macOS will vouch for the download; what it can be
/// held to is the designated requirement of the copy already running, which
/// names the bundle identifier and the signing certificate. A build that does
/// not satisfy it is not this app from this developer, and is refused before it
/// goes anywhere near the installed one.
///
/// Calls back with nil when the swap is done and the app is ready to restart,
/// or with a sentence to show when it is not.
+ (void)installRelease:(EZUpdateCheck *)release
            completion:(void (^)(NSString *_Nullable error))completion;

/// Quits, and starts the copy on disk once this process is gone.
///
/// Waiting matters: `open` on a bundle whose app is still running activates the
/// old process instead of launching the new one, so the update would look like
/// it had not happened.
+ (void)relaunch;

@end

NS_ASSUME_NONNULL_END
