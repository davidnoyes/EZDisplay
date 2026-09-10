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

#include <string>

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
bool EZReleaseFromJSON(const std::string &json, EZRelease *release,
                       std::string *error);

/// What the About box says about this build against the latest release.
///
/// Takes both rather than reading either, so a test can check the wording
/// without the answer depending on which bundle happened to run it.
std::string EZUpdateStatusText(const std::string &current,
                               const std::string &latest);
