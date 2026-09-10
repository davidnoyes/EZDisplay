//
//  MainMenu.swift
//  EZDisplay
//
//  The menu bar, which this app has gone its whole life without.
//
//  An agent app has no menu bar of its own — `LSUIElement` keeps it out of the
//  Dock and out of the bar, and everything it does is reachable from the status
//  item. That reads like a reason not to have one, and it is not, because a menu
//  bar is not only a place to click. It is where AppKit looks for a key
//  equivalent. With no `NSApp.mainMenu` there is nowhere for ⌘C to be found, so
//  the Width and Height fields in the custom-resolutions sheet could be typed
//  into but not pasted into, and ⌘, and ⌘W and ⌘Q did nothing anywhere.
//
//  The status menu declares ⌘, next to Settings, which looks like the shortcut
//  works and is not the same thing: a status item's key equivalents are live
//  only while that menu is open, so it is a label rather than a binding.
//
//  When the app is frontmost this bar is drawn, which is a visible change for an
//  app that had none. That is the trade, and it is the ordinary one — every
//  agent app with a window of its own makes it.
//
//  Nothing here names a target. Each action goes to the responder chain, which
//  is what lets one Copy item serve whichever text field has focus and lets
//  Settings and About land on the app delegate.
//

import AppKit

@objc final class EZMainMenu: NSObject {

    /// Installs the bar.
    @objc static func install() {
        NSApp.mainMenu = build()
    }

    /// Builds it, without touching the application object, so it can be
    /// inspected in a test.
    ///
    /// The app name is spelled out rather than read from the bundle: this is
    /// only ever built by EZDisplay, and reading `CFBundleName` would make the
    /// titles depend on which bundle the code happens to be running inside —
    /// which, under `xctest`, is not this one.
    @objc static func build() -> NSMenu {
        let bar = NSMenu()
        for menu in [appMenu(), editMenu(), windowMenu()] {
            let holder = NSMenuItem()
            holder.submenu = menu
            bar.addItem(holder)
        }
        return bar
    }

    /// The application menu. macOS draws its title in bold from the bundle name
    /// whatever this says, but the title is what identifies it here.
    ///
    /// No Hide or Show All. Those act on an app's windows, and this one spends
    /// almost all of its life with none open; an item that does nothing visible
    /// is worse than an absent one.
    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "EZDisplay")
        menu.addItem(item("About EZDisplay", Selector(("showAbout"))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", Selector(("showPreferences")), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit EZDisplay", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    /// The clipboard, and the undo stack behind it.
    ///
    /// `undo:` and `redo:` are spelled as bare selectors because no class in
    /// AppKit declares them — they are answered by whatever the field editor
    /// hands them to.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        // A capital Z, which is how AppKit spells Shift-Command-Z. Putting the
        // shift in the modifier mask instead draws the same shortcut and does
        // not fire.
        menu.addItem(item("Redo", Selector(("redo:")), "Z"))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// Close and Minimize, offered for every window and disabled by AppKit for
    /// the ones that cannot take them.
    ///
    /// The Settings window is deliberately not miniaturizable, and the way to
    /// express that is to leave Minimize here and let `performMiniaturize:`
    /// fail to validate against that window. Dropping the item instead would
    /// make the menu change shape depending on which window is in front.
    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}
