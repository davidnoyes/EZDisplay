//
//  Update.mm
//  EZDisplay
//

#import <Foundation/Foundation.h>

#include <vector>

#include "Update.h"

namespace {

// The numbers in a version, in order, with a leading "v" and anything after the
// last digit left out. "v1.2.3-beta.1" and "1.2.3" both come back as {1, 2, 3}.
//
// Written by hand rather than with a scanner because the input is a git tag
// somebody typed, and the useful behaviour on the unexpected is to stop reading
// rather than to fail: a tag that starts with numbers still compares on them.
std::vector<int> Components(const std::string &version)
{
    std::vector<int> parts;
    size_t at = 0;

    if (at < version.size() && (version[at] == 'v' || version[at] == 'V')) {
        at++;
    }

    while (at < version.size() && isdigit((unsigned char) version[at])) {
        int value = 0;

        while (at < version.size() && isdigit((unsigned char) version[at])) {
            value = value * 10 + (version[at] - '0');
            at++;
        }

        parts.push_back(value);

        // Another component only if a dot is followed by more digits, so the
        // dot in "1.2.3-beta.1" ends the number rather than continuing it.
        if (at + 1 < version.size() && version[at] == '.' &&
            isdigit((unsigned char) version[at + 1])) {
            at++;
        } else {
            break;
        }
    }

    return parts;
}

// The string at `key`, or nothing if it is absent or is not a string. GitHub
// sends JSON null for fields it has no value for, which reads back as NSNull
// rather than as nil, so the class has to be checked and not just the pointer.
std::string StringField(NSDictionary *object, NSString *key)
{
    id value = object[key];

    if (![value isKindOfClass:[NSString class]]) {
        return "";
    }

    return [value UTF8String];
}

}  // namespace

int EZCompareVersions(const std::string &a, const std::string &b)
{
    std::vector<int> left = Components(a);
    std::vector<int> right = Components(b);
    size_t count = std::max(left.size(), right.size());

    for (size_t i = 0; i < count; i++) {
        // A component nobody wrote is a zero, so 1.2 and 1.2.0 are one release.
        int mine = i < left.size() ? left[i] : 0;
        int theirs = i < right.size() ? right[i] : 0;

        if (mine != theirs) {
            return mine < theirs ? -1 : 1;
        }
    }

    return 0;
}

bool EZReleaseFromJSON(const std::string &json, EZRelease *release,
                       std::string *error)
{
    NSData *data = [NSData dataWithBytes:json.data() length:json.size()];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0
                                                  error:nil];

    if (![parsed isKindOfClass:[NSDictionary class]]) {
        // A captive network or a proxy in the way, rather than the API.
        *error = "The reply was not a release.";
        return false;
    }

    NSDictionary *object = parsed;
    std::string tag = StringField(object, @"tag_name");

    if (tag.empty()) {
        // The shape of GitHub's own errors: valid JSON, and none of this.
        *error = "The reply named no version.";
        return false;
    }

    // The tag is what the release is called; the version is what it compares
    // as. Stripped here rather than at every comparison, so the difference
    // stops mattering past this point.
    EZRelease found;
    found.version = tag[0] == 'v' ? tag.substr(1) : tag;
    found.notes = StringField(object, @"body");

    id assets = object[@"assets"];

    if ([assets isKindOfClass:[NSArray class]]) {
        for (id asset in (NSArray *) assets) {
            if (![asset isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            std::string url = StringField(asset, @"browser_download_url");

            // Matched on the name rather than on content_type, because the
            // type is whatever was set at upload time and the extension is
            // what decides whether the file can be unpacked.
            if (url.size() > 4 && url.compare(url.size() - 4, 4, ".zip") == 0) {
                found.downloadURL = url;
                break;
            }
        }
    }

    if (found.downloadURL.empty()) {
        // A real release that this app cannot install — a disk image, say.
        // Naming that is better than reaching for the nearest other file,
        // which would download something that is not an app.
        *error = "Release " + found.version + " has nothing to download.";
        return false;
    }

    *release = found;
    return true;
}

std::string EZUpdateStatusText(const std::string &current,
                               const std::string &latest)
{
    switch (EZCompareVersions(current, latest)) {
        case -1:
            // The version is here because "what would I get?" is the question
            // that decides whether to take it.
            return "EZDisplay " + latest + " is available.";
        case 1:
            // A build from the working copy, which is the normal state of the
            // machine this is written on. Naming the release would read as an
            // offer, and taking it would replace the work in progress.
            return "This build is newer than the latest release.";
        default:
            return "EZDisplay is up to date.";
    }
}
