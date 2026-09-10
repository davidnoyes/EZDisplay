//
//  Update.mm
//  EZDisplay
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

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

namespace {

// Whether `text` ends with `suffix`, with a name on it because the alternative
// spelled out three times is what hides an off-by-one.
bool EndsWith(const std::string &text, const std::string &suffix)
{
    return text.size() > suffix.size() &&
           text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

}  // namespace

bool EZUpdateRequirementIsAdHoc(const std::string &requirement)
{
    return requirement.find("cdhash") != std::string::npos;
}

bool EZUpdateCanReplaceBundle(const std::string &bundlePath, std::string *reason)
{
    if (!EndsWith(bundlePath, ".app")) {
        *reason = "EZDisplay is not running from an application bundle, so "
                  "there is nothing to replace.";
        return false;
    }

    // Where macOS mounts the read-only copy it runs a quarantined app from.
    // Matched anywhere in the path, because the parts either side of it are
    // made up fresh for each launch.
    if (bundlePath.find("/AppTranslocation/") != std::string::npos) {
        *reason = "macOS is running EZDisplay from a temporary read-only copy. "
                  "Move EZDisplay to your Applications folder, open it from "
                  "there, and try again.";
        return false;
    }

    reason->clear();
    return true;
}

std::string EZUpdateAppInArchive(const std::vector<std::string> &entries)
{
    std::string found;

    for (const std::string &entry : entries) {
        if (!EndsWith(entry, ".app")) {
            continue;
        }

        // A second candidate makes the first one a guess, and the guess is what
        // would be installed and run.
        if (!found.empty()) {
            return "";
        }

        found = entry;
    }

    return found;
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

std::string EZUpdateStatusForHTTPCode(int code)
{
    if (code == 200)
        return "";

    if (code == 404)
        return "There are no releases yet.";

    return "GitHub answered " + std::to_string(code) + ".";
}

#pragma mark - Asking GitHub

// The releases of this repository, by the name the remote uses. Case matters
// nowhere in the URL, but it does in a diff, so it is spelled as the repository
// is.
static NSString *const kLatestReleaseURL =
    @"https://api.github.com/repos/davidnoyes/EZDisplay/releases/latest";

// Long enough for a slow network, short enough that the button does not look
// stuck. The panel has no cancel, so this is the only bound on the wait.
static const NSTimeInterval kCheckTimeout = 15.0;

@interface EZUpdateCheck ()
@property (copy) NSString *status;
@property (copy, nullable) NSString *version;
@property (copy, nullable) NSString *downloadURL;
@property BOOL updateAvailable;
@end

@implementation EZUpdateCheck

+ (instancetype)failedWith:(NSString *)status
{
    EZUpdateCheck *check = [[EZUpdateCheck alloc] init];
    check.status = status;
    return check;
}

@end

@implementation EZUpdater

/// The bundle this code was compiled into.
///
/// Deliberately not `mainBundle`, which macOS derives from the path the process
/// was started with. The Homebrew cask puts a symlink to this binary on PATH,
/// and running the app by typing `ezdisplay` resolves `mainBundle` to
/// /opt/homebrew/bin — so the version read below came back nil, the update
/// comparison ran against an empty string, and `bundlePath` named a directory
/// that is not a bundle at all.
+ (NSBundle *)ownBundle
{
    return [NSBundle bundleForClass:self];
}

+ (NSString *)currentVersion
{
    NSString *version = [[self ownBundle]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];

    return version ?: @"";
}

+ (NSString *)currentBuild
{
    NSString *build = [[self ownBundle]
        objectForInfoDictionaryKey:@"CFBundleVersion"];

    return build ?: @"";
}

+ (void)checkWithCompletion:(void (^)(EZUpdateCheck *))completion
{
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kLatestReleaseURL]
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
       timeoutInterval:kCheckTimeout];

    // The documented media type for the API. Without it GitHub is free to
    // answer in whatever its current default is.
    [request setValue:@"application/vnd.github+json"
        forHTTPHeaderField:@"Accept"];

    // Answers arrive on a background queue. Everything the callback touches is
    // a window, so the hop to the main thread happens here rather than being
    // left to each caller to remember.
    void (^finish)(EZUpdateCheck *) = ^(EZUpdateCheck *check) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(check);
        });
    };

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
        if (error) {
            finish([EZUpdateCheck failedWith:
                [NSString stringWithFormat:@"Could not reach GitHub: %@",
                                           error.localizedDescription]]);
            return;
        }

        NSInteger code = [(NSHTTPURLResponse *) response statusCode];
        std::string refusal = EZUpdateStatusForHTTPCode((int) code);

        if (!refusal.empty()) {
            finish([EZUpdateCheck failedWith:
                [NSString stringWithUTF8String:refusal.c_str()]]);
            return;
        }

        EZRelease release;
        std::string reason;
        std::string body((const char *) data.bytes, data.length);

        if (!EZReleaseFromJSON(body, &release, &reason)) {
            finish([EZUpdateCheck failedWith:
                [NSString stringWithUTF8String:reason.c_str()]]);
            return;
        }

        std::string current = [[self currentVersion] UTF8String];

        EZUpdateCheck *check = [[EZUpdateCheck alloc] init];
        check.status = [NSString stringWithUTF8String:
            EZUpdateStatusText(current, release.version).c_str()];
        check.version = [NSString stringWithUTF8String:release.version.c_str()];
        check.downloadURL =
            [NSString stringWithUTF8String:release.downloadURL.c_str()];
        check.updateAvailable = EZCompareVersions(current, release.version) < 0;

        finish(check);
    }];

    [task resume];
}

#pragma mark - Installing

// An app is a few megabytes and the button says nothing about progress, so this
// is generous: a download that is merely slow should finish rather than fail.
static const NSTimeInterval kDownloadTimeout = 120.0;

// Unpacks a downloaded archive, using ditto because Foundation cannot read a
// zip and because ditto is what keeps a bundle's signature intact on the way
// out. Anything that damages the signature would fail the check below, which
// would report tampering rather than the unpacking that caused it.
static BOOL Unpack(NSURL *archive, NSURL *into, NSString **error)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
    task.arguments = @[@"-x", @"-k", archive.path, into.path];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    if (![task launchAndReturnError:nil]) {
        *error = @"The download could not be unpacked.";
        return NO;
    }

    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        *error = @"The download was not a readable archive.";
        return NO;
    }

    return YES;
}

// Whether `candidate` satisfies the designated requirement of the copy that is
// running: the same bundle identifier, signed by the same certificate.
//
// This is the whole of the trust decision. A self-signed certificate means
// nothing to Gatekeeper, so nothing in macOS will vouch for the download on its
// own; what it can be measured against is the identity already on the machine,
// which the user approved when they installed this copy.
static BOOL SignedLikeThisApp(NSURL *candidate, NSString **error)
{
    SecCodeRef running = NULL;

    if (SecCodeCopySelf(kSecCSDefaultFlags, &running) != errSecSuccess) {
        *error = @"EZDisplay could not read its own signature.";
        return NO;
    }

    SecRequirementRef requirement = NULL;
    OSStatus status = SecCodeCopyDesignatedRequirement(
        (SecStaticCodeRef) running, kSecCSDefaultFlags, &requirement);
    CFRelease(running);

    if (status != errSecSuccess) {
        *error = @"EZDisplay could not read its own signature.";
        return NO;
    }

    // An ad-hoc requirement would refuse every genuine update as tampered. A
    // developer build is the only way to be here, and saying so is more use
    // than a security warning that is not one.
    CFStringRef text = NULL;

    if (SecRequirementCopyString(requirement, kSecCSDefaultFlags, &text) ==
        errSecSuccess) {
        bool adHoc = EZUpdateRequirementIsAdHoc(
            [(__bridge NSString *) text UTF8String]);
        CFRelease(text);

        if (adHoc) {
            CFRelease(requirement);
            *error = @"This build is signed ad hoc, so it cannot tell a genuine "
                     @"update from any other download. Install a release build "
                     @"to update in place.";
            return NO;
        }
    }

    SecStaticCodeRef downloaded = NULL;
    status = SecStaticCodeCreateWithPath((__bridge CFURLRef) candidate,
                                         kSecCSDefaultFlags, &downloaded);

    if (status != errSecSuccess) {
        CFRelease(requirement);
        *error = @"The download is not a signed application.";
        return NO;
    }

    // Nested code as well as the outer bundle, because a helper or a framework
    // inside it runs with the same privileges the app was granted.
    status = SecStaticCodeCheckValidity(
        downloaded, kSecCSCheckAllArchitectures | kSecCSCheckNestedCode,
        requirement);

    CFRelease(downloaded);
    CFRelease(requirement);

    if (status != errSecSuccess) {
        *error = @"The download is not signed by the same certificate as this "
                 @"copy of EZDisplay, so it has not been installed.";
        return NO;
    }

    return YES;
}

// Everything from an unpacked archive to a replaced bundle. Returns nil when it
// worked, and the sentence to show when it did not.
static NSString *SwapIn(NSURL *unpacked, NSString *installed)
{
    NSFileManager *files = [NSFileManager defaultManager];
    NSArray<NSString *> *names =
        [files contentsOfDirectoryAtPath:unpacked.path error:nil];
    std::vector<std::string> entries;

    for (NSString *name in names) {
        entries.push_back([name UTF8String]);
    }

    std::string app = EZUpdateAppInArchive(entries);

    if (app.empty()) {
        return @"The download did not contain a single application.";
    }

    NSURL *replacement =
        [unpacked URLByAppendingPathComponent:@(app.c_str())];
    NSString *refusal = nil;

    if (!SignedLikeThisApp(replacement, &refusal)) {
        return refusal;
    }

    NSError *failure = nil;

    if (![files replaceItemAtURL:[NSURL fileURLWithPath:installed]
                   withItemAtURL:replacement
                  backupItemName:nil
                         options:0
                resultingItemURL:NULL
                           error:&failure]) {
        return [NSString stringWithFormat:@"EZDisplay could not be replaced: %@",
                                          failure.localizedDescription];
    }

    return nil;
}

+ (void)installRelease:(EZUpdateCheck *)release
            completion:(void (^)(NSString *))completion
{
    NSString *installed = [[self ownBundle] bundlePath];
    std::string refusal;

    // Asked before the download rather than after it, so a copy that cannot be
    // updated says so at once instead of after a wait.
    if (!EZUpdateCanReplaceBundle([installed UTF8String], &refusal)) {
        completion([NSString stringWithUTF8String:refusal.c_str()]);
        return;
    }

    if (release.downloadURL == nil) {
        completion(@"That release has nothing to download.");
        return;
    }

    void (^finish)(NSString *) = ^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    };

    NSURLRequest *request = [NSURLRequest
        requestWithURL:[NSURL URLWithString:release.downloadURL]
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
       timeoutInterval:kDownloadTimeout];

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
        downloadTaskWithRequest:request
              completionHandler:^(NSURL *location, NSURLResponse *response,
                                  NSError *error) {
        if (error) {
            finish([NSString stringWithFormat:@"The download failed: %@",
                                              error.localizedDescription]);
            return;
        }

        NSInteger code = [(NSHTTPURLResponse *) response statusCode];

        if (code != 200) {
            finish([NSString stringWithFormat:@"The download answered %ld.",
                                              (long) code]);
            return;
        }

        NSFileManager *files = [NSFileManager defaultManager];

        // A replacement directory rather than any temporary one, because it is
        // guaranteed to be on the same volume as the app it will replace, which
        // is what lets the swap below be a rename rather than a copy.
        NSURL *work = [files URLForDirectory:NSItemReplacementDirectory
                                    inDomain:NSUserDomainMask
                           appropriateForURL:[NSURL fileURLWithPath:installed]
                                      create:YES
                                       error:nil];

        if (work == nil) {
            finish(@"There was nowhere to unpack the download.");
            return;
        }

        // The downloaded file is deleted as soon as this handler returns, so
        // all of the work happens inside it rather than being scheduled.
        NSString *problem = nil;

        if (Unpack(location, work, &problem)) {
            problem = SwapIn(work, installed);
        }

        [files removeItemAtURL:work error:nil];
        finish(problem);
    }];

    [task resume];
}

+ (void)relaunch
{
    NSString *quoted = [NSString stringWithFormat:@"'%@'",
        [[[self ownBundle] bundlePath]
            stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    int pid = [[NSProcessInfo processInfo] processIdentifier];

    // A shell rather than a direct launch, because the new copy cannot start
    // until this one is gone: `open` on a bundle whose app is still running
    // activates the old process, and the update would look like it had not
    // happened. The child outlives us — launchd adopts it.
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", [NSString stringWithFormat:
        @"while kill -0 %d 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open %@",
        pid, quoted]];

    [task launchAndReturnError:nil];
    [NSApp terminate:nil];
}

@end
