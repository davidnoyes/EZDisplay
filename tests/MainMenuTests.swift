//
//  MainMenuTests.swift
//  EZDisplay
//
//  Tests for the menu bar's shape.
//
//  Building an NSMenu is not I/O, which is the only reason this can be asserted
//  at all — and it is worth asserting, because a missing item here is invisible.
//  Nothing draws wrong and nothing logs: a shortcut simply does nothing, which
//  is indistinguishable from a keyboard that did not send it. That is how ⌘C and
//  ⌘, came to be dead in this app for its whole life without anyone noticing.
//
//  So these tests are about presence and wiring rather than appearance. The
//  selectors matter as much as the titles: an Edit menu whose Copy item is
//  spelled right and points nowhere is exactly as useless as no Edit menu.
//

import XCTest
import AppKit

final class MainMenuTests: XCTestCase {

    private func menu(_ title: String) -> NSMenu? {
        EZMainMenu.build().items.first { $0.submenu?.title == title }?.submenu
    }

    private func item(_ title: String, in menuTitle: String) -> NSMenuItem? {
        menu(menuTitle)?.items.first { $0.title == title }
    }

    // MARK: - The menus themselves

    /// Three, and only three. A File menu would have no files to manage and a
    /// View menu nothing to show or hide, and the guidelines are against putting
    /// up a menu to hold one disabled item.
    func testTheBarCarriesTheThreeMenusThatHoldShortcuts() {
        let titles = EZMainMenu.build().items.compactMap { $0.submenu?.title }
        XCTAssertEqual(titles, ["EZDisplay", "Edit", "Window"])
    }

    /// Every top-level item is a container and nothing else. AppKit puts
    /// `submenuAction:` on an item the moment it is given a submenu, so that
    /// selector — rather than nil — is what "opens its menu and does nothing
    /// else" looks like. Any other action would fire on a click of the title.
    func testEveryTopLevelItemIsASubmenu() {
        for item in EZMainMenu.build().items {
            XCTAssertNotNil(item.submenu, "\(item.title) has no submenu")
            XCTAssertEqual(item.action, Selector(("submenuAction:")),
                           "\(item.title) is not meant to be clickable")
        }
    }

    // MARK: - The app menu

    /// The shortcut the Human Interface Guidelines name by name, and the one
    /// this file exists for. The status menu declares it too, but a status
    /// item's key equivalents are only live while that menu is open.
    func testSettingsIsOnCommandComma() {
        let settings = item("Settings…", in: "EZDisplay")
        XCTAssertEqual(settings?.keyEquivalent, ",")
        XCTAssertEqual(settings?.keyEquivalentModifierMask, .command)
        XCTAssertEqual(settings?.action, Selector(("showPreferences")))
    }

    /// Named Settings, not Preferences: macOS renamed it in Ventura, and the
    /// window this opens is titled to match.
    func testTheAppMenuDoesNotSayPreferences() {
        XCTAssertNil(item("Preferences…", in: "EZDisplay"))
    }

    func testQuitIsOnCommandQ() {
        let quit = item("Quit EZDisplay", in: "EZDisplay")
        XCTAssertEqual(quit?.keyEquivalent, "q")
        XCTAssertEqual(quit?.keyEquivalentModifierMask, .command)
        XCTAssertEqual(quit?.action, #selector(NSApplication.terminate(_:)))
    }

    /// About comes first and stands alone, which is the one ordering rule the
    /// guidelines state outright for this menu.
    func testAboutIsFirstAndInAGroupOfItsOwn() {
        let app = menu("EZDisplay")
        XCTAssertEqual(app?.items.first?.title, "About EZDisplay")
        XCTAssertEqual(app?.items[1].isSeparatorItem, true)
    }

    // MARK: - The Edit menu

    /// The clipboard, which is the half of this that is not about windows. The
    /// Width and Height fields in the custom-resolutions sheet are ordinary
    /// text fields, and until this menu existed nothing turned ⌘V into a paste.
    func testTheClipboardShortcutsAreWired() {
        let expected: [(String, String, Selector)] = [
            ("Undo",       "z", Selector(("undo:"))),
            ("Redo",       "Z", Selector(("redo:"))),
            ("Cut",        "x", #selector(NSText.cut(_:))),
            ("Copy",       "c", #selector(NSText.copy(_:))),
            ("Paste",      "v", #selector(NSText.paste(_:))),
            ("Select All", "a", #selector(NSText.selectAll(_:))),
        ]
        for (title, key, action) in expected {
            let found = item(title, in: "Edit")
            XCTAssertNotNil(found, "Edit has no \(title)")
            XCTAssertEqual(found?.keyEquivalent, key, "\(title) is on the wrong key")
            XCTAssertEqual(found?.action, action, "\(title) points nowhere")
        }
    }

    /// Redo is Shift-Command-Z, which AppKit expresses as a capital Z rather
    /// than as a shift in the modifier mask. Both spellings draw the same
    /// shortcut in the menu and only one of them fires.
    func testRedoDoesNotCarryAnExplicitShift() {
        XCTAssertEqual(item("Redo", in: "Edit")?.keyEquivalentModifierMask, .command)
    }

    // MARK: - The Window menu

    /// ⌘W, so a window opened from the status menu can be closed without
    /// reaching for the mouse.
    func testCloseIsOnCommandW() {
        let close = item("Close", in: "Window")
        XCTAssertEqual(close?.keyEquivalent, "w")
        XCTAssertEqual(close?.action, #selector(NSWindow.performClose(_:)))
    }

    /// Minimize is offered and left to AppKit to disable. The Settings window
    /// is deliberately not miniaturizable, so `performMiniaturize:` validates
    /// itself away there and stays live for the windows that can take it —
    /// which is what the guidelines ask for, rather than hiding the item.
    func testMinimizeIsOfferedRatherThanOmitted() {
        let minimize = item("Minimize", in: "Window")
        XCTAssertEqual(minimize?.keyEquivalent, "m")
        XCTAssertEqual(minimize?.action, #selector(NSWindow.performMiniaturize(_:)))
    }

    // MARK: - Dispatch

    /// Nothing here names a target. Every one of these actions is answered by
    /// something further along the responder chain — the field editor, the key
    /// window, or the app delegate — and pinning a target would send them all
    /// to one object that answers almost none of them.
    func testNoItemNamesATarget() {
        for top in EZMainMenu.build().items {
            for item in top.submenu?.items ?? [] {
                XCTAssertNil(item.target, "\(item.title) is pinned to a target")
            }
        }
    }
}
