//
//  Utils.swift
//  EZDisplay
//
//  Small helpers with no home of their own: the System Integrity Protection
//  check that decides whether the app can write to /System, the Application
//  Support path, the quoting and wrapping that make an administrator-privileged
//  AppleScript call safe, and the alert that reports it when one fails.
//

import AppKit

/// The exact lines `csrutil status` prints when a protection is off. These are
/// the tool's own wording, so they are matched literally rather than parsed.
private let sipDisabledReports: Set<String> = [
    "System Integrity Protection status: disabled.",
    "System Integrity Protection status: disabled (Apple Internal).",
    "Filesystem Protections: disabled"
]

/// Whether System Integrity Protection is on, as reported by `csrutil`.
///
/// Every failure path answers `true` — including a non-zero exit, which the
/// previous version answered `false` to, against its own stated intent.
/// Claiming SIP is off when it is on would send the app down the
/// direct-write-to-`/System` route and the write would fail; claiming it is on
/// when it is off only costs the app a faster path.
func isSIPActive() -> Bool {
    let csrutil = Process()
    csrutil.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
    csrutil.arguments = ["status"]

    let readEnd = Pipe()
    csrutil.standardOutput = readEnd

    do {
        try csrutil.run()
    } catch {
        return true
    }

    let reported = readEnd.fileHandleForReading.readDataToEndOfFile()
    csrutil.waitUntilExit()

    // If csrutil output can't be decoded, assume SIP is active — the safe
    // default, since it keeps the app off the direct-write-to-/System path.
    guard csrutil.terminationStatus == 0,
          let report = String(data: reported, encoding: .utf8) else { return true }

    return !report.split(separator: "\n").contains {
        sipDisabledReports.contains($0.trimmingCharacters(in: .whitespaces))
    }
}

/// Wraps `value` as a single POSIX-shell-quoted token that is safe to embed in
/// a shell command. Any embedded single quote is emitted as the `'\''` idiom so
/// the value can never break out of its quoting. This is defense-in-depth for
/// the administrator-privileged `do shell script` calls: even if a path ever
/// carried a shell metacharacter, it would be treated as literal text.
func shellQuoted(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The user's Application Support directory, with `suffix` appended.
///
/// Falls back to the conventional location under the home directory on the
/// rare occasion the search API returns nothing.
func getAppSupportDir(withTrailingPath suffix: String = "") -> URL {
    let searched = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: false)
    let base = searched ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")

    return base.appendingPathComponent(suffix).standardizedFileURL
}

extension NSAppleScript {
    private static let adminSuffix = " with administrator privileges"

    /// How the `source` handed to the initializer should be treated.
    enum ScriptType {
        /// A shell command, to be wrapped in `do shell script "…"`.
        case shell
        /// AppleScript source, used exactly as it stands.
        case apple
    }

    /// Turns `source` into the AppleScript that will actually be compiled.
    ///
    /// A shell command has to survive being embedded in an AppleScript
    /// double-quoted literal, so the backslash is escaped before the double
    /// quote — the other order would escape the escapes this adds, and a
    /// backslash-quote pair would end the literal early. AppleScript source is
    /// already in its final form and is passed through untouched.
    private static func scriptText(for source: String, as type: ScriptType) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespaces)

        guard type == .shell else { return trimmed }

        let embedded = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return "do shell script \"\(embedded)\""
    }

    convenience init?(source: String, asType: ScriptType = .shell, withAdminPriv: Bool = false) {
        var script = NSAppleScript.scriptText(for: source, as: asType)

        // The clause goes outside the quoted command, and only if the caller
        // has not already written it: asking twice is a syntax error.
        if withAdminPriv && !script.hasSuffix(NSAppleScript.adminSuffix) {
            script += NSAppleScript.adminSuffix
        }

        self.init(source: script)
    }

    /// Compiles and runs `source`, returning the error dictionary if either
    /// step fails and `nil` on success.
    static func executeAndReturnError(source: String,
                                      asType: ScriptType = .shell,
                                      withAdminPriv: Bool = false) -> NSDictionary? {
        guard let script = NSAppleScript(source: source,
                                         asType: asType,
                                         withAdminPriv: withAdminPriv) else {
            return NSDictionary()
        }

        var failure: NSDictionary? = nil
        script.executeAndReturnError(&failure)
        return failure
    }
}

public extension NSAlert {
    /// Presents the error dictionary an `NSAppleScript` run hands back.
    @objc convenience init(fromDict: NSDictionary, style: Style = .critical) {
        self.init()

        window.level = .floating
        alertStyle = style

        let brief = fromDict["NSAppleScriptErrorBriefMessage"] as? String

        // An error carrying no brief message is worth seeing in the log: the
        // alert can only offer the user a generic line.
        if brief == nil {
            print(fromDict)
        }

        messageText = brief ?? "Unknown error, please try again."
    }
}
