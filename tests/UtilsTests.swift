//
//  UtilsTests.swift
//  EZDisplay
//
//  Tests for the pure logic in src/Utils.swift: the Application Support path,
//  and the quoting, escaping and wrapping that guard the
//  administrator-privileged AppleScript path.
//
//  These pin the current behavior so the file can be rewritten underneath
//  them. Anything that would run a process, compile AppleScript, or touch a
//  display stays out — that work belongs to the scratch probes, not here.
//  Building an NSAppleScript or an NSAlert is fine: neither one executes or
//  presents anything until it is asked to.
//

import XCTest

final class ShellQuotedTests: XCTestCase {
    func testWrapsAPlainValueInSingleQuotes() {
        XCTAssertEqual(shellQuoted("plain"), "'plain'")
    }

    func testAnEmptyValueStaysAQuotedEmptyToken() {
        XCTAssertEqual(shellQuoted(""), "''")
    }

    func testAnEmbeddedSingleQuoteCannotBreakOut() {
        // The POSIX idiom: close the quote, emit an escaped quote, reopen.
        XCTAssertEqual(shellQuoted("it's"), #"'it'\''s'"#)
    }

    func testAMetacharacterIsLeftLiteral() {
        XCTAssertEqual(shellQuoted("a; rm -rf /"), "'a; rm -rf /'")
    }
}

/// The escaping is only reachable through the initializer, so it is checked
/// through the finished script text.
final class ScriptTypeEscapingTests: XCTestCase {
    private func shellScript(_ command: String) -> String? {
        return NSAppleScript(source: command, asType: .shell)?.source
    }

    func testShellEscapesTheDoubleQuoteThatWouldEndTheLiteral() {
        XCTAssertEqual(shellScript(#"a"b"#), #"do shell script "a\"b""#)
    }

    func testShellEscapesTheBackslash() {
        XCTAssertEqual(shellScript(#"a\b"#), #"do shell script "a\\b""#)
    }

    func testTheBackslashIsEscapedBeforeTheQuote() {
        // Escaping in the other order would turn a backslash-quote pair into
        // an escaped backslash followed by a live quote, ending the literal.
        XCTAssertEqual(shellScript(#"a\"b"#), #"do shell script "a\\\"b""#)
    }

    func testAppleScriptSourcePassesThroughUntouched() {
        let script = NSAppleScript(source: #"a\"b"#, asType: .apple)
        XCTAssertEqual(script?.source, #"a\"b"#)
    }
}

/// The initializer composes four steps — trim, escape, wrap, append the admin
/// clause — and only the composition can catch them being ordered wrongly or
/// dropped. Reading `source` back builds the script without compiling or
/// running it, so nothing here executes a shell command.
final class AppleScriptCompositionTests: XCTestCase {
    func testAShellCommandIsWrappedInDoShellScript() {
        let script = NSAppleScript(source: "echo hi", asType: .shell)
        XCTAssertEqual(script?.source, #"do shell script "echo hi""#)
    }

    func testTheAdminClauseIsAppendedOutsideTheQuotedCommand() {
        // The clause belongs to the AppleScript statement, so it has to land
        // after the closing quote. Inside it would just be text echoed.
        let script = NSAppleScript(source: "echo hi", asType: .shell, withAdminPriv: true)
        XCTAssertEqual(script?.source,
                       #"do shell script "echo hi" with administrator privileges"#)
    }

    func testTheAdminClauseIsNotAppendedTwice() {
        let script = NSAppleScript(source: "do something with administrator privileges",
                                   asType: .apple,
                                   withAdminPriv: true)
        XCTAssertEqual(script?.source, "do something with administrator privileges")
    }

    func testWithoutAdminPrivilegesNoClauseIsAdded() {
        let script = NSAppleScript(source: "echo hi", asType: .shell, withAdminPriv: false)
        XCTAssertEqual(script?.source, #"do shell script "echo hi""#)
    }

    func testAppleScriptSourceIsNotWrapped() {
        let script = NSAppleScript(source: #"tell app "Finder" to activate"#, asType: .apple)
        XCTAssertEqual(script?.source, #"tell app "Finder" to activate"#)
    }

    func testSurroundingWhitespaceIsTrimmedBeforeWrapping() {
        // Trimming has to happen inside the quotes, not around the finished
        // statement, or the wrapper itself would carry the padding.
        let script = NSAppleScript(source: "   echo hi   ", asType: .shell)
        XCTAssertEqual(script?.source, #"do shell script "echo hi""#)
    }

    func testAQuoteInTheCommandCannotEndTheEmbeddedLiteral() {
        // The whole point of the escaping: the inner quotes stay inside the
        // do-shell-script literal instead of closing it early.
        let script = NSAppleScript(source: #"echo "hi""#, asType: .shell)
        XCTAssertEqual(script?.source, #"do shell script "echo \"hi\"""#)
    }
}

final class AppSupportDirTests: XCTestCase {
    func testTheBareDirectoryIsApplicationSupport() {
        XCTAssertTrue(getAppSupportDir().path.hasSuffix("Application Support"))
    }

    func testTheTrailingPathIsAppended() {
        // src/RestoreSettings.swift builds the backup directory this way, so
        // a dropped suffix would silently relocate every saved backup.
        let dir = getAppSupportDir(withTrailingPath: "Foo/Bar")
        XCTAssertEqual(Array(dir.pathComponents.suffix(3)), ["Application Support", "Foo", "Bar"])
    }
}

final class AlertFromDictTests: XCTestCase {
    func testTheBriefMessageBecomesTheAlertText() {
        let alert = NSAlert(fromDict: ["NSAppleScriptErrorBriefMessage": "boom"])
        XCTAssertEqual(alert.messageText, "boom")
        XCTAssertEqual(alert.alertStyle, .critical)
    }

    func testADictionaryWithNoBriefMessageFallsBackToAGenericLine() {
        let alert = NSAlert(fromDict: [:])
        XCTAssertEqual(alert.messageText, "Unknown error, please try again.")
    }

    func testTheStyleIsHonored() {
        let alert = NSAlert(fromDict: ["NSAppleScriptErrorBriefMessage": "note"],
                            style: .informational)
        XCTAssertEqual(alert.alertStyle, .informational)
    }
}
