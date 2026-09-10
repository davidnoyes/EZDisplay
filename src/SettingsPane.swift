//
//  SettingsPane.swift
//  EZDisplay
//
//  Which pane the Settings window opens on.
//
//  Reopening on the pane last used is what the guidelines ask for, and the whole
//  of it that can go wrong is the lookup: an identifier stored by an earlier
//  build can name a pane this one does not have. Written inline that is a
//  `firstIndex(of:)` and an index of -1 nobody sees until it ships, so it lives
//  here instead, where a test can reach it.
//
//  Identifiers rather than positions, so inserting a pane does not silently
//  reopen everyone on the one next to the one they left.
//

import Foundation

enum EZSettingsPane {
    /// Where the chosen pane is remembered.
    static let defaultsKey = "EZSettingsPane"

    /// A pane, in the order the toolbar reads.
    ///
    /// The raw values are the stored identifiers, so the case order here is the
    /// one thing that decides where a tab appears. Night Shift sits next to
    /// Display because that is what it changes; it is not in General, which is
    /// for how this app behaves rather than what the screen does.
    enum Pane: String, CaseIterable {
        case display
        case nightShift = "nightshift"
        case audio
        case general
    }

    /// The panes to build, given what this Mac can do.
    ///
    /// Night Shift is dropped rather than shown empty or grayed out, the way
    /// the status menu drops its item: a tab that opens on nothing says the
    /// feature is there and broken. Every other pane is unconditional, so this
    /// takes the one flag rather than a set of them.
    static func panes(nightShiftSupported: Bool) -> [Pane] {
        Pane.allCases.filter { $0 != .nightShift || nightShiftSupported }
    }

    /// The position of `identifier` in `identifiers`, or the first pane when it
    /// is missing, unknown, or there is nothing to choose between.
    static func index(of identifier: String?, in identifiers: [String]) -> Int {
        guard let identifier, let found = identifiers.firstIndex(of: identifier) else { return 0 }
        return found
    }
}
