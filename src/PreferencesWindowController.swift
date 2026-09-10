//
//  PreferencesWindowController.swift
//  EZDisplay
//
//  Programmatic Settings window: a toolbar of panes, one per subject. Display
//  holds the per-display mode and color-mode tables; Night Shift holds its
//  warmth and schedule; Audio holds the volume keys and the permission they
//  need; General holds the menu-behavior toggles. Which panes there are is
//  decided in SettingsPane.swift, where a test can read it. Built in code (not
//  the storyboard) so it is self-contained and reviewable. Menu-behavior prefs
//  live in UserDefaults and are read by the ObjC++ menu builder in
//  EZAppDelegate.mm.
//

import Cocoa
import ServiceManagement

// MARK: - Preferences store

@objc class EZPrefs: NSObject {
    @objc static let showStandardKey    = "EZShowStandard"     // Bool
    @objc static let showRefreshMenuKey  = "EZShowRefreshMenu"  // Bool
    @objc static let curatedCountKey     = "EZCuratedCount"     // Int
    @objc static let launchAtLoginKey    = "EZLaunchAtLogin"    // Bool (persisted mirror)
    @objc static let nightShiftScheduleKey = "EZNightShiftSchedule"  // Int, an EZNightShiftMode
    @objc static let volumeKeysKey       = "EZVolumeKeys"       // Bool
    @objc static let muteAtZeroKey       = "EZMuteAtZero"       // Bool

    /// Posted when a menu-behavior pref changes, so the menu can rebuild.
    @objc static let changedNotification = Notification.Name("EZPrefsChanged")

    @objc static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showStandardKey:   true,
            showRefreshMenuKey: true,
            curatedCountKey:    6,
            // Custom rather than sunset to sunrise, because a custom window
            // always runs: sunset needs location services, and defaulting to a
            // schedule the machine may not be allowed to keep would give the
            // menu's Scheduled item nothing to do.
            nightShiftScheduleKey: EZNightShiftMode.custom.rawValue,
            // On, because until this pref existed the keys were taken whenever
            // the grant and a display allowed it, and shipping a switch that
            // silently turns a working feature off is not a new option.
            volumeKeysKey: true,
        ])
        // muteAtZeroKey is not registered. Its default is off, which is what an
        // unregistered Bool already reads as, and an entry saying so would be
        // one more place for the two to disagree.
    }

    static var showStandard: Bool {
        get { UserDefaults.standard.bool(forKey: showStandardKey) }
        set { UserDefaults.standard.set(newValue, forKey: showStandardKey); notifyChanged() }
    }
    static var showRefreshMenu: Bool {
        get { UserDefaults.standard.bool(forKey: showRefreshMenuKey) }
        set { UserDefaults.standard.set(newValue, forKey: showRefreshMenuKey); notifyChanged() }
    }
    static var curatedCount: Int {
        get { max(1, UserDefaults.standard.integer(forKey: curatedCountKey)) }
        set { UserDefaults.standard.set(newValue, forKey: curatedCountKey); notifyChanged() }
    }

    /// Whether the volume keys should be redirected to the display's speakers.
    ///
    /// The change notification is what makes turning this off take effect: the
    /// menu rebuild it triggers is where the tap is told how many displays it
    /// has, and off is told zero. Nothing here stops the tap — a tap that is
    /// never handed a target passes every key straight through, which is the
    /// same behavior as not having one and needs no second mechanism.
    static var volumeKeys: Bool {
        get { UserDefaults.standard.bool(forKey: volumeKeysKey) }
        set { UserDefaults.standard.set(newValue, forKey: volumeKeysKey); notifyChanged() }
    }

    /// Whether a volume that reaches 0% should mute the display as well.
    ///
    /// Off by default. It is an extra DDC write at one end of the dial, and a
    /// display that then refuses to unmute is a display with no sound and no
    /// obvious reason why — worth offering, not worth assuming.
    static var muteAtZero: Bool {
        get { UserDefaults.standard.bool(forKey: muteAtZeroKey) }
        set { UserDefaults.standard.set(newValue, forKey: muteAtZeroKey) }
    }

    /// Which schedule the menu's **Scheduled** item and `nightshift scheduled`
    /// should run.
    ///
    /// A schedule already running is the answer, because that is what the user
    /// is looking at; the stored value is only the memory of what to go back to
    /// once Night Shift has been switched off, which takes the mode — and so
    /// the kind — with it.
    static var nightShiftSchedule: EZNightShiftMode {
        get {
            let live = EZNightShift.mode()
            if live != .off { return live }

            let stored = UserDefaults.standard.integer(forKey: nightShiftScheduleKey)
            let kind = EZNightShiftMode(rawValue: stored) ?? .custom
            // A sunset schedule stored before location services were turned off
            // reads back as custom, so that every caller — the menu, the command
            // line, and the popup below — is told the one schedule that would
            // actually run. The stored value is left alone rather than
            // corrected, because it is the choice to go back to if location
            // services come on again. A live sunset mode above is exempt: what
            // the daemon is running is true whatever permission now says.
            if kind == .sunset && !EZNightShift.sunSchedulePermitted() { return .custom }
            return kind
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: nightShiftScheduleKey)
            // A schedule already running changes to the new kind now. Storing
            // it alone would leave the popup and the tint disagreeing until
            // something else moved the mode.
            if EZNightShift.mode() != .off { _ = EZNightShift.setMode(newValue) }
            notifyChanged()
        }
    }

    // Resolved values for the ObjC++ menu builder — one source of truth for
    // defaults instead of raw NSUserDefaults reads with a duplicated fallback.
    @objc static func resolvedShowStandard() -> Bool { showStandard }
    @objc static func resolvedShowRefreshMenu() -> Bool { showRefreshMenu }
    @objc static func resolvedCuratedCount() -> Int { curatedCount }
    @objc static func resolvedVolumeKeys() -> Bool { volumeKeys }
    @objc static func resolvedNightShiftSchedule() -> EZNightShiftMode { nightShiftSchedule }
    @objc static func setResolvedNightShiftSchedule(_ value: EZNightShiftMode) {
        nightShiftSchedule = value
    }

    // The same values the other way, for the command line's `prefs` subcommand.
    @objc static func setResolvedShowStandard(_ value: Bool) { showStandard = value }
    @objc static func setResolvedShowRefreshMenu(_ value: Bool) { showRefreshMenu = value }
    @objc static func setResolvedCuratedCount(_ value: Int) { curatedCount = value }

    /// Whether the app is registered to start at login.
    ///
    /// The system is asked rather than the mirrored default, because the two can
    /// disagree: a login item removed in System Settings leaves the default
    /// saying it is still on, and reporting that would be reporting a wish.
    @objc static func resolvedLaunchAtLogin() -> Bool {
        guard #available(macOS 13.0, *) else {
            return UserDefaults.standard.bool(forKey: launchAtLoginKey)
        }

        return SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item, returning nil on success or the
    /// reason it failed. The default is only a mirror, so it is written after the
    /// system has agreed rather than before.
    @objc static func setLaunchAtLogin(_ value: Bool) -> String? {
        guard #available(macOS 13.0, *) else {
            return "This version of macOS has no login-item service EZDisplay can use."
        }

        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return error.localizedDescription
        }

        UserDefaults.standard.set(value, forKey: launchAtLoginKey)
        return nil
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

// MARK: - Window controller

@objc class PreferencesWindowController: NSWindowController {
    @objc convenience init() {
        let window = NSWindow(contentViewController: PreferencesTabViewController())
        // Not miniaturizable. A settings window is not somewhere to leave
        // parked in the Dock, and the guidelines are explicit that its minimize
        // button should be dimmed.
        window.styleMask = [.titled, .closable]
        // No content size. Each pane declares its own width and lets its
        // content decide its height, and the tab controller resizes the window
        // to whichever pane is showing — which is what the old hand-tuned
        // 540 × 700 was standing in for, badly, when one page held everything.
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

// MARK: - Pane shell

/// The Settings window's panes and the toolbar that switches between them.
///
/// One page held all of this until now, and the cost was paid in height: two
/// scrolling lists were sized by hand at 216 and 108 points so the whole column
/// would still fit a 1280 × 800 screen, and the comments on those numbers say
/// so. Splitting the page does not spend that headroom — the lists keep their
/// heights here — but it does stop the total growing every time something is
/// added, because the window is now only ever as tall as one pane.
final class PreferencesTabViewController: NSTabViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // A toolbar of panes, which is what a settings window with more than one
        // page is supposed to look like. Not customizable and always visible
        // come with the style rather than needing to be asked for.
        tabStyle = .toolbar

        // Read before building, because building overwrites it. Adding the first
        // item makes NSTabView select it, which calls `tabView(_:didSelect:)`
        // below, which stores "display" — so a read taken after the loop is
        // never the stored pane, it is always the first one. The window has
        // reopened on Display since the day this was written, and reading the
        // two lines in the order they appear does not show it.
        let storedPane = UserDefaults.standard.string(forKey: EZSettingsPane.defaultsKey)

        // Which panes there are, and in what order, is decided in
        // `EZSettingsPane` so a test can read it. What each one is made of is
        // decided here, because a view controller is not something a test of
        // that list should have to build.
        for pane in EZSettingsPane.panes(nightShiftSupported: EZNightShift.supported()) {
            let label: String, symbol: String, controller: NSViewController
            switch pane {
            case .display:
                (label, symbol, controller) = ("Display", "display", DisplayPaneViewController())
            case .nightShift:
                (label, symbol, controller) = ("Night Shift", "moon", NightShiftPaneViewController())
            case .audio:
                (label, symbol, controller) = ("Audio", "speaker.wave.2", AudioPaneViewController())
            case .general:
                (label, symbol, controller) = ("General", "gearshape", GeneralPaneViewController())
            }
            // The pane's name goes on the view controller, not on the tab item.
            // A tab item's label is bound to its controller's title, and in
            // toolbar style the window title is taken from the same place — so
            // setting the label instead leaves the controller's title nil and
            // the window reads "Untitled" the moment a pane is switched.
            controller.title = label
            let item = NSTabViewItem(viewController: controller)
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }

        // Reopen where the window was left. The identifiers are read back off
        // the items just added rather than kept in a second list, so the two
        // cannot drift apart.
        selectedTabViewItemIndex = EZSettingsPane.index(
            of: storedPane,
            in: tabViewItems.compactMap { $0.identifier as? String })
    }

    /// Remembers the pane, so the window reopens on it.
    ///
    /// The window's title is not set here. In toolbar style the tab controller
    /// titles the window from the selected pane itself, which is what the
    /// guidelines ask for and what Safari and Mail do; anything set here is
    /// overwritten on the next switch.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let identifier = tabViewItem?.identifier as? String else { return }
        UserDefaults.standard.set(identifier, forKey: EZSettingsPane.defaultsKey)
    }
}

// MARK: - Display pane

class DisplayPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nativeLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let colorStatusLabel = NSTextField(labelWithString: "")
    private let colorTable = NSTableView()
    private let colorScroll = NSScrollView()
    private let colorApplyButton = NSButton(title: "Apply Selected Color Mode", target: nil, action: nil)
    private let colorHelpButton = NSButton()
    private let colorHelpPopover = NSPopover()
    private let colorHelpText = NSTextField(wrappingLabelWithString: "")

    private var displays: [EZDisplayInfo] = []
    private var modes: [EZDisplayMode] = []
    private var colorModes: [EZColorMode] = []
    private var selectedDisplayID: CGDirectDisplayID = 0
    private var nativeW = 0
    private var nativeH = 0
    /// Built once per mode reload rather than per row: the list runs to over a
    /// thousand rows and each lookup would otherwise rescan IOKit.
    private var customResolutionsWC: CustomResolutionsWindowController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 700))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        reloadDisplays()
        // The display can change without us: another app, System Settings, or
        // the system itself dropping HDR because the new timing cannot carry it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The active mode may have changed since the window was last shown.
        reloadModes()
    }

    @objc private func screenParametersChanged() {
        // Displays, not just modes: this notification also reports a display
        // arriving or leaving, so the picker has to be rebuilt as well.
        reloadDisplays()
        // HDR trails a timing change by a second or two, and the system moves it
        // on its own — off when the new timing cannot carry it, back on when one
        // can — so the read above is too early to see where it landed. Coalesce
        // bursts the way the menu rebuild does, since one change can post this
        // several times.
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(reloadColorMode), object: nil)
        perform(#selector(reloadColorMode), with: nil, afterDelay: 3.0)
    }

    // MARK: UI construction

    private func buildUI() {
        // Display picker row
        let displayLabel = NSTextField(labelWithString: "Display:")
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)
        let displayRow = NSStackView(views: [displayLabel, displayPopup])
        displayRow.orientation = .horizontal
        displayRow.spacing = 8
        nativeLabel.textColor = .secondaryLabelColor

        // Mode table inside a scroll view
        //
        // Neither autoresizing default lets a declared width mean what it says.
        // Left alone, the autoresizing style spends the difference between the
        // columns and the table on whichever ones it likes — which is how
        // "Refresh" came to read "Refr…" while its neighbors kept the width
        // they were given. And whatever the widths, AppKit pads every column by
        // a flat amount, so a table whose columns sum to its own width overflows
        // and the rightmost one loses its tail.
        //
        // `.inset` is the current look — rows held off the edges with a rounded
        // selection behind them — and it moves both numbers: roughly, the first
        // column starts 10pt in and each one is padded by 15 rather than plain's
        // 17. Roughly, because those two do not add up to what the table
        // actually measures — there is a point or two of slack between columns
        // that belongs to neither. So the widths below were read off a running
        // table rather than worked out from those figures, and anything that
        // changes them wants reading off one again.
        tableView.style = .inset
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Each column holds its widest string with room to spare — "3440 × 1440  ✓"
        // is 97pt and "Retina (HiDPI) · Native" 134. The three put the right edge
        // at 481, which is where the bezelled version had it: 19pt short of the
        // scroll view's 500, so the 17 a legacy scroller takes is still there for
        // anyone running with "always show scroll bars" on.
        let resCol = NSTableColumn(identifier: .init("res"));   resCol.title = "Resolution"; resCol.width = 130
        let typeCol = NSTableColumn(identifier: .init("type")); typeCol.title = "Type";       typeCol.width = 195
        let hzCol = NSTableColumn(identifier: .init("hz"));     hzCol.title = "Refresh";      hzCol.width = 100
        tableView.addTableColumn(resCol)
        tableView.addTableColumn(typeCol)
        tableView.addTableColumn(hzCol)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(applySelected)
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        // No bezel. The inset style draws its own edges — that is what the 10pt
        // is for — and a box around it as well is the frame twice.
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // 216, not 240: the color-mode section below costs the height of a
        // second list, and the window has to stay inside the 775pt a 1280×800
        // screen leaves it.
        scroll.heightAnchor.constraint(equalToConstant: 216).isActive = true

        let applyButton = NSButton(title: "Apply Selected Resolution", target: self, action: #selector(applySelected))

        // Color mode: one writable control, the mode list. What the display
        // itself reports as valid at its current timing, so it changes with the
        // resolution and refresh rate selected above, and with HDR.
        //
        // HDR is deliberately not a control here, only in the menu. CoreDisplay
        // reports it as a per-display system preference, not as a property of
        // the link, so the box stayed ticked while the list underneath it showed
        // an SDR mode as the one running — two true statements that read as a
        // contradiction. The menu has no list beside it to disagree with.
        colorApplyButton.target = self
        colorApplyButton.action = #selector(applySelectedColorMode)

        // The explanation is four separate points — how the list is ordered, how
        // to apply a row, that a mode does not persist, and where HDR lives —
        // and it was a five-line paragraph under the table, read once and then
        // in the way forever. Behind a help icon it is there when wanted and
        // costs nothing when not.
        //
        // A button rather than an image view, and a popover as well as the
        // tooltip, because the text it replaced was always on screen. A tooltip
        // alone is a hover, and a hover is unreachable by keyboard, unreadable
        // to VoiceOver on a view that is not a control, and dismissed on the
        // system's timer rather than the reader's. The button is in the key-view
        // loop, so Tab reaches it and Space opens the same text in something
        // that stays until dismissed.
        colorHelpButton.image = NSImage(systemSymbolName: "questionmark.circle",
                                        accessibilityDescription: nil)
        colorHelpButton.imagePosition = .imageOnly
        colorHelpButton.isBordered = false
        colorHelpButton.contentTintColor = .secondaryLabelColor
        colorHelpButton.target = self
        colorHelpButton.action = #selector(showColorHelp)
        colorHelpButton.setAccessibilityLabel("About color modes")

        // Width pinned, height left to the text. A wrapping label has no width
        // it prefers — it will take whatever it is given and grow downwards —
        // so without this the popover sizes itself to a one-character column.
        // 440pt clears the longest line the note is wrapped to, so the popover
        // shows the same line breaks as the tooltip rather than re-wrapping
        // them into a ragged second set.
        colorHelpText.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let helpVC = NSViewController()
        helpVC.view = NSView()
        helpVC.view.addSubview(colorHelpText)
        colorHelpText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colorHelpText.widthAnchor.constraint(equalToConstant: 440),
            colorHelpText.leadingAnchor.constraint(equalTo: helpVC.view.leadingAnchor, constant: 14),
            colorHelpText.trailingAnchor.constraint(equalTo: helpVC.view.trailingAnchor, constant: -14),
            colorHelpText.topAnchor.constraint(equalTo: helpVC.view.topAnchor, constant: 14),
            colorHelpText.bottomAnchor.constraint(equalTo: helpVC.view.bottomAnchor, constant: -14),
        ])
        colorHelpPopover.contentViewController = helpVC
        colorHelpPopover.behavior = .transient

        // One row per mode, laid out as bit depth plus a badge per property,
        // rather than the run-on sentence this replaced. The properties are what
        // you compare between rows — which of these is 10-bit, which keeps
        // RGB 4:4:4, which drops to Limited Range — and a paragraph of text per
        // row makes that comparison something the reader has to do by hand.
        colorTable.headerView = nil
        colorTable.style = .inset
        colorTable.rowHeight = 24
        colorTable.gridStyleMask = []
        colorTable.intercellSpacing = NSSize(width: 0, height: 2)
        colorTable.usesAlternatingRowBackgroundColors = false
        // A row is now the thing you act on, so it has to look selectable.
        // Double-click applies, matching the resolution table above.
        colorTable.target = self
        colorTable.doubleAction = #selector(applySelectedColorMode)
        // Sized explicitly, like the resolution table's columns above, rather
        // than left at NSTableColumn's 100pt default: the default only widens
        // via autoresizing, which reacts to a frame change and so is not
        // guaranteed to have fired before the first reloadData. A clipped badge
        // would have no recovery path either — the window is not resizable and
        // the list has no horizontal scroller.
        // The scroll view spans the stack's 500pt, with no bezel to come off it.
        // The inset style takes 22 of that — 10 at the leading edge and 15 of
        // column padding, less the 3 it hands back — and the vertical
        // scroller's gutter comes off it as well: an overlay on most Macs and
        // free, but real under "always show scroll bars", where a row sized to
        // the full width puts its last badge behind it. Reserved either way, so
        // the column is 500 − 22 − 17. Badges are what would be clipped, in a
        // window that cannot be resized or scrolled sideways.
        let colorCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        colorCol.width = 500 - 22 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        colorCol.minWidth = colorCol.width
        colorTable.addTableColumn(colorCol)
        colorTable.dataSource = self
        colorTable.delegate = self
        colorScroll.documentView = colorTable
        colorScroll.hasVerticalScroller = true
        colorScroll.borderType = .noBorder
        colorScroll.translatesAutoresizingMaskIntoConstraints = false
        // Kept short deliberately: the window is not resizable and has no outer
        // scroll, so every point added here is a point closer to overflowing a
        // small screen. The list scrolls internally instead.
        colorScroll.heightAnchor.constraint(equalToConstant: 108).isActive = true

        // Bottom action buttons
        let editButton = NSButton(title: "Edit Custom Resolutions…", target: self, action: #selector(editCustom))
        let restoreButton = NSButton(title: "Restore Defaults…", target: self, action: #selector(restoreDefaults))
        let restoreAllButton = NSButton(title: "Restore All Displays…", target: self, action: #selector(restoreAllDefaults))
        let bottomRow = NSStackView(views: [editButton, restoreButton, restoreAllButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12

        let colorHeaderRow = NSStackView(views: [NSTextField.groupHeader("Color mode"),
                                                 colorHelpButton])
        colorHeaderRow.orientation = .horizontal
        colorHeaderRow.alignment = .centerY
        colorHeaderRow.spacing = 6

        let stack = NSStackView(views: [displayRow, nativeLabel, scroll, applyButton,
                                        NSBox.separator(), colorHeaderRow,
                                        colorStatusLabel, colorScroll,
                                        colorApplyButton,
                                        NSBox.separator(), bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            // 540 wide, which is where the column widths above were measured.
            // Stated rather than left to the content, because the tab controller
            // sizes the window to each pane and two panes that disagreed by a
            // few points would make it twitch sideways on every switch.
            view.widthAnchor.constraint(equalToConstant: 540),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            colorScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            colorScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        // The pane's height, as distinct from its minimum. The required
        // constraint above only stops the content overflowing; this is what
        // makes `fittingSize` tight enough to size the window from, and it
        // yields rather than breaking when a section is hidden and the content
        // no longer reaches the bottom.
        let bottom = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        bottom.priority = .defaultHigh
        bottom.isActive = true

        // The tab controller resizes the window to each pane's
        // preferredContentSize, and leaves it alone when that is zero — which
        // is why the window kept the taller pane's height and left the shorter
        // one standing in a field of empty space.
        preferredContentSize = view.fittingSize
    }

    // MARK: Data

    private func reloadDisplays() {
        let previous = selectedDisplayID
        displays = EZDisplays.onlineDisplays()
        displayPopup.removeAllItems()
        for d in displays { displayPopup.addItem(withTitle: d.name) }
        displayPopup.isEnabled = displays.count > 1
        // Stay on the display the user picked. This now runs again whenever the
        // displays change, so it must not drag the selection back to the first
        // one. The lookup misses on the first build, where there is no previous
        // selection, and when the selected display has been unplugged — both of
        // which should fall back to the first display.
        if let idx = displays.firstIndex(where: { $0.displayID == previous }) {
            displayPopup.selectItem(at: idx)
            selectedDisplayID = previous
        } else {
            selectedDisplayID = displays.first?.displayID ?? 0
        }
        reloadModes()
    }

    private func reloadModes() {
        guard selectedDisplayID != 0 else {
            modes = []; nativeW = 0; nativeH = 0
            // Clear the native line too. It used to be left alone, which was
            // harmless while this ran once at startup with a display attached,
            // but it now runs when the last display is unplugged and would
            // otherwise keep describing a display that has gone.
            nativeLabel.stringValue = ""
            tableView.reloadData(); reloadColorMode(); return
        }
        // Native reference for the selected display.
        if let info = displays.first(where: { $0.displayID == selectedDisplayID }) {
            nativeW = Int(info.nativeWidth)
            nativeH = Int(info.nativeHeight)
            if nativeW > 0 {
                let hz = info.nativeRefresh > 0 ? " · \(info.nativeRefresh) Hz" : ""
                nativeLabel.stringValue = "Native: \(nativeW) × \(nativeH)\(hz)"
            } else {
                nativeLabel.stringValue = "Native: unknown"
            }
        }
        // Dedup the private-API list by geometry + refresh rate, sorted desc.
        // Several raw modes share one key — measured: 1618 raw modes collapse to
        // 1424 on a 34" Philips, so 194 collisions — and keeping the first arrival
        // discards the mode the display is actually running whenever it is not the
        // first to arrive. Nothing is then marked current and the table highlights
        // no row. Prefer the current mode on a collision.
        var seen: [String: Int] = [:]
        var deduped: [EZDisplayMode] = []
        for m in EZDisplays.modes(forDisplay: selectedDisplayID) {
            let key = "\(m.width)x\(m.height)@\(m.scale)/\(m.refreshRate)"
            if let existing = seen[key] {
                if m.isCurrent { deduped[existing] = m }
            } else {
                seen[key] = deduped.count
                deduped.append(m)
            }
        }
        deduped.sort {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.scale != $1.scale { return $0.scale > $1.scale }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.refreshRate > $1.refreshRate
        }
        modes = deduped
        tableView.reloadData()
        if let idx = modes.firstIndex(where: { $0.isCurrent }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
        // The valid color modes depend on the timing in force, so this belongs
        // with the mode reload rather than only with the display picker.
        reloadColorMode()
    }

    /// Color mode is read through a private, unversioned API that only covers
    /// natively connected external displays, so every path here has to be able
    /// to say "not available" instead of showing something wrong.
    @objc private func reloadColorMode() {
        guard selectedDisplayID != 0 else {
            colorStatusLabel.stringValue = "Color mode is not available for this display."
            colorStatusLabel.isHidden = false
            colorModes = []
            colorTable.reloadData()
            colorScroll.isHidden = true
            colorApplyButton.isHidden = true
            colorHelpButton.isHidden = true
            return
        }

        // Ordered by EZColorModeUI, so this list and the one in the status menu
        // put the same row at the top.
        colorModes = EZColorModeUI.sortedModes(forDisplay: selectedDisplayID)
        colorTable.reloadData()

        // The status line is for when there is nothing to show. Once the rows
        // are there the filled marker says which one is running, so repeating it
        // in words above the list is clutter.
        colorStatusLabel.isHidden = !colorModes.isEmpty
        if colorModes.isEmpty {
            colorStatusLabel.stringValue =
                "No color modes reported for this display at its current timing."
        }
        // An empty bordered box is worse than no box: on the internal panel,
        // which reports nothing at all, it read as a list that had failed to
        // load rather than one that does not apply.
        colorScroll.isHidden = colorModes.isEmpty
        colorApplyButton.isHidden = colorModes.isEmpty

        // Says what the list is a list *of*, which the old asterisk footnote
        // never did. Four things a reader needs and cannot get from the rows:
        // how the order was decided, how to act on a row, that the badges are
        // worth pointing at since a tooltip advertises itself to nobody, and
        // that a mode applied here does not stick. The last one matters most —
        // nothing is written to disk, so a mode survives exactly as long as the
        // timing it was chosen under. The examples are examples, not a list:
        // anything that restarts the link takes the mode with it, and sleep and
        // wake have not been tested. Better to promise less than to name a case
        // that turns out not to hold.
        //
        // The ordering clause names its criterion rather than claiming "best",
        // because the ranking is a judgment and an unexplained one looks like a
        // bug: a 4:4:4 badge sits below a 4:2:2 one whenever the 4:2:2 mode is
        // the HDR one, and nothing on screen would otherwise say that was
        // deliberate.
        //
        // Wrapped by hand. A tooltip lays out the string it is given, so without
        // the breaks this is one line as wide as the four sentences are long,
        // and the bullets are what stopped it being a wall of text in the first
        // place.
        var note = """
            Modes the display reports for the timing it is running now, in
            quality order — HDR first, then whichever keeps the most color
            detail.

            •  Double-click a mode to switch to it, or select it and choose
               Apply.
            •  Point at a badge to see what it means.
            •  A mode you apply is not saved. Anything that restarts the
               display link drops it — a change of resolution, refresh rate,
               or HDR, and possibly sleep and wake — and disconnecting the
               display or restarting the Mac always clears it.
            """
        // Only when there is something to point at. The menu gives a display that
        // cannot do HDR no item at all rather than a disabled one, so this
        // sentence would otherwise send the reader hunting for a control that is
        // not there — a worse outcome than the "not supported by this display"
        // the removed checkbox used to say.
        // The second sentence because the coupling is otherwise a surprise: an
        // HDR mode cannot be carried without HDR itself, so choosing one turns
        // it on, and choosing an SDR mode turns it off. Better said here than
        // discovered from a checkbox that moved on its own.
        if EZColorModes.supportsHDR(forDisplay: selectedDisplayID) {
            note += """

                •  Turn HDR on or off from the EZDisplay menu. Choosing a mode \
                also moves it, since the transfer function belongs to it.
                """
        }
        // Three routes to the same string: hover, click or Space, and VoiceOver.
        // accessibilityHelp is set explicitly rather than left to AppKit's
        // fallback from toolTip, which is not something the documentation
        // promises for every role.
        colorHelpButton.toolTip = note
        colorHelpButton.setAccessibilityHelp(note)
        colorHelpText.stringValue = note
        // Nothing to explain when there is no list, and the icon would be the
        // only thing left under the heading.
        colorHelpButton.isHidden = colorModes.isEmpty

        // Select the running mode rather than only scrolling to it. The list is
        // taller than the box so it is usually below the fold on open, and now
        // that a row is actionable, leaving nothing selected would put the Apply
        // button in a state with no row to explain it.
        if let idx = colorModes.firstIndex(where: { $0.isCurrent }) {
            colorTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            colorTable.scrollRowToVisible(idx)
        }
        updateColorApplyButton()
    }

    /// Nothing to apply when the selected row is the mode already running, which
    /// is the state the window opens in. Saying so with a grayed-out button beats
    /// a click that correctly does nothing and looks broken doing it.
    private func updateColorApplyButton() {
        let row = colorTable.selectedRow
        colorApplyButton.isEnabled = row >= 0 && row < colorModes.count && !colorModes[row].isCurrent
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === colorTable ? colorModes.count : modes.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // One delegate serves both tables; only the color list has a button
        // whose state depends on the selection.
        guard notification.object as? NSTableView === colorTable else { return }
        updateColorApplyButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === colorTable { return EZColorModeUI.colorRow(colorModes[row]) }
        let m = modes[row]
        // Pixels, not points: a HiDPI mode is negotiated on the cable at its
        // backing size, so 2752 × 1152 Retina is a 5504 × 2304 signal.
        let pxW = Int((Float(m.width) * m.scale).rounded())
        let pxH = Int((Float(m.height) * m.scale).rounded())
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "res":  text = "\(m.width) × \(m.height)" + (m.isCurrent ? "  ✓" : "")
        case "type":
            let isNative = nativeW > 0 && pxW == nativeW && pxH == nativeH
            text = (m.isHiDPI ? "Retina (HiDPI)" : "Standard") + (isNative ? " · Native" : "")
        case "hz":   text = m.refreshRate > 0 ? "\(m.refreshRate) Hz" : "—"
        default:     text = ""
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf); c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = text
        // Cleared unconditionally: cells are recycled across columns and rows,
        // and no column in this table explains itself any more. Left unset, a
        // tooltip from an earlier build's HDR column could survive a reused cell.
        cell.toolTip = nil
        return cell
    }

    // MARK: Actions

    @objc private func displayChanged() {
        let idx = displayPopup.indexOfSelectedItem
        if idx >= 0 && idx < displays.count {
            selectedDisplayID = displays[idx].displayID
            reloadModes()
        }
    }

    /// Shows the color-mode explanation in a popover, for readers who cannot
    /// hover: Tab reaches the button, Space fires this, and the popover stays
    /// until it is dismissed.
    @objc private func showColorHelp() {
        if colorHelpPopover.isShown {
            colorHelpPopover.performClose(nil)
        } else {
            colorHelpPopover.show(relativeTo: colorHelpButton.bounds,
                                  of: colorHelpButton, preferredEdge: .maxY)
        }
    }

    @objc private func applySelected() {
        let row = tableView.selectedRow
        guard row >= 0 && row < modes.count else { return }
        let m = modes[row]
        let detail = m.refreshRate > 0 ? "\(m.width) × \(m.height) · \(m.refreshRate) Hz"
                                       : "\(m.width) × \(m.height)"
        // Apply through the confirm-or-revert safety flow.
        SafeApply.setDisplayMode(m.displayID, modeNum: Int32(m.modeNum), detail: detail)
        // Reflect the new current mode once it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reloadModes() }
    }

    /// Switches the display to the selected color mode. The apply itself, and
    /// the confirm-or-revert around it, are shared with the status menu's
    /// picker — one route to the hardware, so one thing to get right.
    @objc private func applySelectedColorMode() {
        let row = colorTable.selectedRow
        guard row >= 0, row < colorModes.count else { return }
        EZColorModeUI.apply(colorModes[row],
                            toDisplay: selectedDisplayID,
                            in: view.window) { [weak self] in self?.reloadColorMode() }
    }

    @objc private func editCustom() {
        guard selectedDisplayID != 0 else { return }
        let info = displays.first(where: { $0.displayID == selectedDisplayID })
        let ratio = (info != nil && info!.nativeHeight > 0)
            ? Double(info!.nativeWidth) / Double(info!.nativeHeight) : 0
        let wc = CustomResolutionsWindowController(
            vendorID: CGDisplayVendorNumber(selectedDisplayID),
            productID: CGDisplayModelNumber(selectedDisplayID),
            displayName: info?.name ?? "",
            displayAspectRatio: ratio)
        customResolutionsWC = wc   // retain while shown
        wc.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func restoreDefaults() {
        guard selectedDisplayID != 0 else { return }
        let name = displays.first(where: { $0.displayID == selectedDisplayID })?.name ?? "this display"
        // Read now, next to the name they are asked about, and not again once
        // the answer comes back. A sheet leaves the window standing while it
        // waits, and a monitor unplugged in that time takes `reloadDisplays()`
        // with it: the selection would move, and the restore would go to a
        // display nobody was asked about while the sheet still said this one.
        let vendorID = CGDisplayVendorNumber(selectedDisplayID)
        let productID = CGDisplayModelNumber(selectedDisplayID)
        let confirm = NSAlert()
        confirm.messageText = "Restore default settings for \(name)?"
        confirm.informativeText = "This removes EZDisplay's custom resolution overrides for this display. A reboot may be required to fully apply."
        confirm.addButton(withTitle: "Restore")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        present(confirm) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }

            let item = RestoreSettingsItem(title: "", action: #selector(self.restoreDefaults),
                                           vendorID: vendorID,
                                           productID: productID,
                                           displayName: name)
            let result = NSAlert()
            if let error = item.restoreSettings() {
                result.messageText = (error["NSAppleScriptErrorBriefMessage"] as? String) ?? "Restore failed."
                result.alertStyle = .critical
            } else {
                result.messageText = "Restore complete."
            }
            self.presentAfterSheet(result)
        }
    }

    /// Unlike `restoreDefaults`, this reaches displays that are not currently
    /// connected — the only route to undoing an override for a monitor that has
    /// since been unplugged.
    @objc private func restoreAllDefaults() {
        let paths  = RestoreSettingsItem.managedOverrideRelativePaths()
        let others = RestoreSettingsItem.unmanagedOverrideRelativePaths()
        let othersNote = others.isEmpty ? "" :
            "\n\nLeft untouched: \(others.count) override \(others.count == 1 ? "file" : "files") EZDisplay did not create. Another tool may own \(others.count == 1 ? "it" : "them"), so removing \(others.count == 1 ? "it" : "them") could discard settings EZDisplay never made. Use Restore Defaults… on a specific display to remove one of these."

        guard RestoreSettingsItem.restoreAllScript(for: paths) != nil else {
            let empty = NSAlert()
            empty.messageText = "Nothing to restore."
            empty.informativeText = "EZDisplay has not created any display overrides on this Mac.\(othersNote)"
            present(empty)
            return
        }

        let plural = paths.count == 1 ? "display" : "displays"
        let confirm = NSAlert()
        confirm.messageText = "Restore default settings for all displays?"
        confirm.informativeText = "This removes the custom resolution overrides EZDisplay created for \(paths.count) \(plural) from \(CustomResolutionsStore.rootdir), including displays that are not currently connected. A reboot may be required to fully apply.\(othersNote)"
        confirm.addButton(withTitle: "Restore All")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        present(confirm) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }

            let result = NSAlert()
            if let error = RestoreSettingsItem.restoreAllSettings() {
                result.messageText = (error["NSAppleScriptErrorBriefMessage"] as? String) ?? "Restore failed."
                result.alertStyle = .critical
            } else {
                result.messageText = "Restore complete."
            }
            self.presentAfterSheet(result)
        }
    }
}

// MARK: - Night Shift pane

/// Night Shift's warmth and its schedule.
///
/// Its own pane rather than a section of General, which is for how this app
/// behaves: this changes what the screen looks like, which is where anyone
/// would go looking for it. Not a section of the display pane either — one
/// warmth and one schedule serve every screen, and putting it under a display
/// picker would invite the reading that it could differ between them.
///
/// The on and off stays in the status menu. It is one click and belongs where a
/// click is cheapest; a pane is where the values behind it live.
///
/// Built only on a Mac that can do Night Shift, so nothing here re-checks
/// `EZNightShift.supported()` — the pane's existence is the check.
class NightShiftPaneViewController: NSViewController {

    private let warmthSlider = NSSlider()
    private let warmthLabel = NSTextField(labelWithString: "")
    private let schedulePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scheduleFrom = NSDatePicker()
    private let scheduleTo = NSDatePicker()
    private var scheduleWindowRow: NSStackView?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 200))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        // Warmth posts no change notification of its own — measured, and
        // recorded in CoreBrightness.h — so an open window cannot be told that
        // System Settings moved it. Coming back to this app is the cue instead,
        // which covers the way anyone would actually hit it: leave, change it
        // there, come back. Not the app delegate's Night Shift observer, which
        // holds one block for the whole process and would lose the menu its
        // rebuild.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadWarmth),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // The schedule is reachable from three places — here, System Settings,
        // and the command line — so it needs the same cue for the same reason.
        // A second observer rather than one combined selector, because the two
        // reloads are independent and either may be the one that fails.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadSchedule),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadWarmth()
        reloadSchedule()
    }

    // MARK: UI construction

    private func buildUI() {
        // Warmth is here rather than in the menu because it is one value on a
        // scale: a menu can carry the on and off the status menu already shows,
        // and not this.
        warmthSlider.minValue = 0
        warmthSlider.maxValue = 100
        reloadWarmth()
        warmthSlider.target = self
        warmthSlider.action = #selector(warmthChanged)
        // Continuous, so the tint follows the knob. Each step writes the value
        // straight through, which is what makes the preview live. Committing
        // every step rather than only on release was measured before it was
        // kept: 220 committed writes, a full drag of this slider, take 2.1 ms
        // in total, and are indistinguishable from uncommitted ones. The daemon
        // coalesces, so there is no per-step disk write to avoid and no reason
        // to carry a commit flag around.
        warmthSlider.isContinuous = true
        warmthSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let warmthRow = NSStackView(views: [warmthLabel, warmthSlider])
        warmthRow.orientation = .horizontal
        warmthRow.alignment = .centerY
        warmthRow.spacing = 8

        // Which schedule the menu's Scheduled item runs. The menu offers the
        // three states because they are one exclusive choice a click can make;
        // this is the setting behind one of them, and it is a setting rather
        // than a state — it keeps its value while Night Shift is off, which is
        // the whole reason it is not in the menu.
        schedulePopup.target = self
        schedulePopup.action = #selector(scheduleKindChanged)
        let scheduleRow = NSStackView(views: [NSTextField(labelWithString: "Schedule:"),
                                              schedulePopup])
        scheduleRow.orientation = .horizontal
        scheduleRow.alignment = .centerY
        scheduleRow.spacing = 8

        for picker in [scheduleFrom, scheduleTo] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.hourMinute]
            picker.target = self
            picker.action = #selector(scheduleWindowChanged)
            // AppKit measures this control a few points short and clips the
            // last digit, and `sizeToFit` gives the same short answer. The
            // slack is added to what it measured rather than stated as a
            // width, because that measurement is the one thing that already
            // knows how wide the locale's time format is: a 12-hour one
            // carries "AM" as well and would not fit a number chosen here.
            picker.widthAnchor.constraint(
                equalToConstant: picker.intrinsicContentSize.width + 6).isActive = true
        }
        let windowRow = NSStackView(views: [NSTextField(labelWithString: "From:"), scheduleFrom,
                                            NSTextField(labelWithString: "To:"), scheduleTo])
        windowRow.orientation = .horizontal
        windowRow.alignment = .centerY
        windowRow.spacing = 8
        scheduleWindowRow = windowRow

        reloadSchedule()

        // Where the switch is. System Settings puts the on and off on the same
        // page as these two, so a pane with a warmth slider and no switch reads
        // as one that has lost it. Saying so costs a line; leaving it to be
        // discovered costs a hunt through the menu bar.
        let switchNote = NSTextField(labelWithString:
            "Turn Night Shift on or off from the EZDisplay menu bar item.")
        switchNote.textColor = .secondaryLabelColor
        switchNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // No "Night Shift" heading over the stack. In toolbar style the pane
        // titles the window, so a heading repeating it is the frame twice.
        let stack = NSStackView(views: [warmthRow, scheduleRow, windowRow, switchNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            // The same 540 the other panes declare, so switching panes moves
            // the window's height and not its width.
            view.widthAnchor.constraint(equalToConstant: 540),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        // Both as in the display pane, and for the same two reasons.
        let bottom = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        bottom.priority = .defaultHigh
        bottom.isActive = true
        preferredContentSize = view.fittingSize
    }

    private func updateWarmthLabel() {
        warmthLabel.stringValue = "Warmth: \(warmthSlider.integerValue)%"
    }

    /// Puts the slider back on the live warmth. The value belongs to the system
    /// rather than to this window, so anything else — the command line, System
    /// Settings — can move it while the window is closed.
    @objc private func reloadWarmth() {
        // -1 means the daemon would not answer. Nothing can be shown for that,
        // so the slider sits at the cool end rather than at a number nobody set.
        warmthSlider.integerValue = max(0, EZNightShift.warmthPercent())
        updateWarmthLabel()
    }

    /// Puts the schedule controls back on what is really set, the way
    /// `reloadWarmth` does: the command line and System Settings can both move
    /// this while the window is closed.
    @objc private func reloadSchedule() {
        // Sunset to sunrise is dropped rather than disabled where location
        // services are off, which is what System Settings does. A grayed row
        // would say the choice exists and this Mac cannot have it, and there is
        // nothing the user can do about it from here.
        let sunAllowed = EZNightShift.sunSchedulePermitted()
        schedulePopup.removeAllItems()
        if sunAllowed { schedulePopup.addItem(withTitle: "Sunset to Sunrise") }
        schedulePopup.addItem(withTitle: "Custom")

        // `nightShiftSchedule` already reads a stored sunset schedule back as
        // custom where location services are off, so the popup and the menu
        // agree without this method writing anything: a reload runs on every
        // refocus, and a write there would move a running schedule the user had
        // not touched.
        let custom = EZPrefs.nightShiftSchedule == .custom || !sunAllowed
        schedulePopup.selectItem(at: custom && sunAllowed ? 1 : 0)

        var from: Int = 0, to: Int = 0
        if EZNightShift.getScheduleFrom(&from, to: &to) {
            scheduleFrom.dateValue = Self.time(minutesPastMidnight: from)
            scheduleTo.dateValue = Self.time(minutesPastMidnight: to)
        }
        // Only the custom schedule has a window to show, and an empty pair of
        // time fields under "Sunset to Sunrise" reads as a window that is not
        // being honored.
        scheduleWindowRow?.isHidden = !custom
    }

    private static func time(minutesPastMidnight minutes: Int) -> Date {
        // The day is arbitrary — only the hour and minute are read back — so any
        // date the calendar will build one on will do.
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60,
                              second: 0, of: Date()) ?? Date()
    }

    private static func minutesPastMidnight(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: Actions

    // Setting the warmth does not switch Night Shift on, so a drag here with it
    // off changes nothing on screen. That is the same thing System Settings
    // does, and the on and off is one click away in the status menu.
    @objc private func warmthChanged() {
        // A refused write puts the slider back on the value that is really
        // set, rather than leaving it showing a number nothing accepted. The
        // same rule the status menu follows: report what is, not what was
        // asked for.
        guard EZNightShift.setWarmthPercent(warmthSlider.integerValue) else {
            reloadWarmth()
            return
        }
        updateWarmthLabel()
    }

    @objc private func scheduleKindChanged() {
        EZPrefs.nightShiftSchedule =
            schedulePopup.titleOfSelectedItem == "Custom" ? .custom : .sunset
        reloadSchedule()
    }

    @objc private func scheduleWindowChanged() {
        let from = Self.minutesPastMidnight(of: scheduleFrom.dateValue)
        let to = Self.minutesPastMidnight(of: scheduleTo.dateValue)
        // Both ends on the same minute is a window with no length, which macOS
        // is not documented to say which way it reads. Put back rather than
        // written, for the same reason a refused warmth is.
        if from == to || !EZNightShift.setScheduleFrom(from, to: to) {
            reloadSchedule()
        }
    }
}

// MARK: - Audio pane

/// The volume keys, and what reaching the bottom of the dial should do.
///
/// This pane exists because the permission the feature needs was being asked for
/// from the status menu, by an item that appeared while the grant was missing and
/// vanished once it arrived. A menu whose contents come and go is the one thing
/// the menu guidelines rule out, and a permission request is not a menu command
/// anyway: it is a piece of setup, with an explanation attached, and setup
/// belongs in Settings.
///
/// Shown whatever the Mac has attached. A pane that appeared only when a monitor
/// with speakers was plugged in would be missing at the moment someone went
/// looking for why the keys did nothing.
class AudioPaneViewController: NSViewController {

    private let statusIcon = NSImageView()
    // Wrapping, so that the width of this pane is decided by the paragraphs and
    // not by whatever this row happens to say. A plain label here holds the
    // window open to its own single line, and the first draft of it did: two
    // points wider than the 540 every pane declares, which broke that constraint
    // rather than wrapping.
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let continueButton = NSButton()
    private var grantObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 200))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()

        // The grant is given in System Settings, in another app, and this
        // notification is the only word of it that arrives. Not
        // `didBecomeActive`, which would be enough for someone who walks over to
        // System Settings and comes back, and not enough for the system prompt
        // the Continue button raises: that can be answered without EZDisplay
        // ever becoming active, leaving this pane still asking for something it
        // has already been given.
        //
        // The app delegate observes the same notification for its own reasons,
        // and this is a second observer rather than a hook into that one because
        // the delegate's lives for the whole process and this one lives as long
        // as the window.
        grantObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main) { [weak self] _ in
                // The trust database is written a moment after the notification,
                // so asking now can still get the old answer — the same half
                // second the delegate waits, for the same reason.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.showGrantState()
                }
        }
    }

    deinit {
        if let grantObserver {
            DistributedNotificationCenter.default().removeObserver(grantObserver)
        }
    }

    /// Revoking the grant is as invisible as giving it, so the state is read
    /// again every time the pane is shown rather than only when it is built.
    override func viewWillAppear() {
        super.viewWillAppear()
        showGrantState()
    }

    // MARK: UI construction

    private func buildUI() {
        let useKeys = NSButton(checkboxWithTitle: "Use the volume keys to control the display",
                               target: self, action: #selector(toggleVolumeKeys))
        useKeys.state = EZPrefs.volumeKeys ? .on : .off

        let explanation = NSTextField(wrappingLabelWithString:
            "Seeing the volume keys at all needs Accessibility permission. They are "
            + "redirected to a monitor's own speakers only when macOS has no volume "
            + "of its own to move — plug in headphones and they go straight back to "
            + "the system.")
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.preferredMaxLayoutWidth = 478

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        // What is left of the indented width once the icon, the gaps and the
        // button have taken theirs.
        statusLabel.preferredMaxLayoutWidth = 340

        continueButton.title = "Continue"
        continueButton.bezelStyle = .rounded
        continueButton.target = self
        continueButton.action = #selector(requestAccessibility)

        let statusRow = NSStackView(views: [statusIcon, statusLabel, continueButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        let muteAtZero = NSButton(checkboxWithTitle: "Mute the display when the volume reaches 0%",
                                  target: self, action: #selector(toggleMuteAtZero))
        muteAtZero.state = EZPrefs.muteAtZero ? .on : .off
        // What the option costs, since the reason to leave it off is not obvious
        // from its name: it is an extra exchange on a bus that is already slow.
        let muteNote = NSTextField(wrappingLabelWithString:
            "Sends the mute command as well as a volume of zero. Some monitors "
            + "take one and not the other.")
        muteNote.textColor = .secondaryLabelColor
        muteNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        muteNote.preferredMaxLayoutWidth = 478

        let stack = NSStackView(views: [NSTextField.groupHeader("Volume keys"),
                                        useKeys,
                                        Self.indented(explanation),
                                        Self.indented(statusRow),
                                        NSBox.separator(),
                                        NSTextField.groupHeader("Volume"),
                                        muteAtZero,
                                        Self.indented(muteNote)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            // The same 540 the other panes declare, so switching panes moves the
            // window's height and not its width.
            view.widthAnchor.constraint(equalToConstant: 540),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        let bottom = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        bottom.priority = .defaultHigh
        bottom.isActive = true

        showGrantState()
        preferredContentSize = view.fittingSize
    }

    /// Lines a view up with the *title* of the checkbox above it rather than
    /// with the box, which is where the guidelines put text that explains one
    /// setting. Left at the margin it reads as another item in the section
    /// instead of as a note on the one above.
    ///
    /// 22 points is the box plus the gap AppKit puts after it. There is no API
    /// that reports it, and `NSButton.alignmentRectInsets` does not describe it,
    /// so it is measured rather than derived.
    private static func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        return row
    }

    /// One row, two states, and no button once there is nothing left to press.
    ///
    /// Granted is reported rather than left silent, because the alternative — an
    /// empty space where the request used to be — reads as the setting having
    /// gone missing rather than as the setting being satisfied.
    private func showGrantState() {
        let granted = EZVolumeKeys.authorized()

        statusIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill"
                                                             : "exclamationmark.triangle.fill",
                                   accessibilityDescription: nil)
        statusIcon.contentTintColor = granted ? .systemGreen : .systemOrange
        statusLabel.stringValue = granted
            ? "Volume keys are enabled."
            : "Accessibility permission has not been given."
        continueButton.isHidden = granted
    }

    // MARK: Actions

    /// Asks for the grant, and then opens the list where it is given.
    ///
    /// Both, because either one alone is a button that sometimes does nothing.
    /// The system prompt is shown only for an app the privacy database has not
    /// heard of, so an app that has been granted the permission and then lost it
    /// — which is what a rebuild does, and what revoking it does — gets no
    /// prompt at all and no sign that the button was pressed. Opening the pane
    /// covers that. And the request is still needed, because it is what puts a
    /// first-time app into the list for the pane to show.
    ///
    /// The answer comes back through the observer in `viewDidLoad` rather than
    /// from here: `requestAuthorization` returns long before the user decides.
    @objc private func requestAccessibility() {
        EZVolumeKeys.requestAuthorization()

        if let pane = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(pane)
        }
    }

    @objc private func toggleVolumeKeys(_ sender: NSButton) {
        EZPrefs.volumeKeys = (sender.state == .on)
    }

    @objc private func toggleMuteAtZero(_ sender: NSButton) {
        EZPrefs.muteAtZero = (sender.state == .on)
    }
}

// MARK: - General pane

/// How this app behaves: what the status menu shows, and whether it starts with
/// the Mac.
///
/// Nothing here changes the screen. Anything that does has a pane of its own,
/// which is what sends someone to Display or Night Shift rather than through
/// this one first.
class GeneralPaneViewController: NSViewController {

    private let curatedStepper = NSStepper()
    private let curatedLabel = NSTextField(labelWithString: "")
    private var launchAtLoginCheck: NSButton?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    // MARK: UI construction

    private func buildUI() {
        let showStandard = checkbox("Show standard (non-HiDPI) resolutions in menu",
                                    action: #selector(toggleShowStandard))
        showStandard.state = EZPrefs.showStandard ? .on : .off
        let showRefresh = checkbox("Show Refresh Rate submenu",
                                   action: #selector(toggleShowRefresh))
        showRefresh.state = EZPrefs.showRefreshMenu ? .on : .off

        curatedStepper.minValue = 1
        curatedStepper.maxValue = 20
        curatedStepper.integerValue = EZPrefs.curatedCount
        curatedStepper.target = self
        curatedStepper.action = #selector(curatedChanged)
        updateCuratedLabel()
        let curatedRow = NSStackView(views: [curatedLabel, curatedStepper])
        curatedRow.orientation = .horizontal
        curatedRow.spacing = 8

        var optionViews: [NSView] = [showStandard, showRefresh, curatedRow]
        if #available(macOS 13.0, *) {
            let login = checkbox("Launch EZDisplay at login", action: #selector(toggleLaunchAtLogin))
            login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            launchAtLoginCheck = login
            optionViews.append(login)
        }

        let stack = NSStackView(views: [NSTextField.groupHeader("Menu options")] + optionViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            // The same 540 the display pane declares, so switching panes moves
            // the window's height and not its width.
            view.widthAnchor.constraint(equalToConstant: 540),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        // Both as in the display pane, and for the same two reasons.
        let bottom = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        bottom.priority = .defaultHigh
        bottom.isActive = true
        preferredContentSize = view.fittingSize
    }

    private func checkbox(_ title: String, action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func updateCuratedLabel() {
        curatedLabel.stringValue = "Recommended list length: \(curatedStepper.integerValue)"
    }

    // MARK: Actions

    @objc private func toggleShowStandard(_ sender: NSButton) { EZPrefs.showStandard = (sender.state == .on) }
    @objc private func toggleShowRefresh(_ sender: NSButton)  { EZPrefs.showRefreshMenu = (sender.state == .on) }

    @objc private func curatedChanged() {
        EZPrefs.curatedCount = curatedStepper.integerValue
        updateCuratedLabel()
    }

    @available(macOS 13.0, *)
    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(sender.state == .on, forKey: EZPrefs.launchAtLoginKey)
        } catch {
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            let a = NSAlert()
            a.messageText = "Could not update login item."
            a.informativeText = error.localizedDescription
            present(a)
        }
    }
}

private extension NSTextField {
    /// The heading over a group of controls in a pane.
    ///
    /// Semibold, which is what macOS Settings gives its own group headings and
    /// what the separators here were already trying to say on their own: at one
    /// weight the heading and the checkbox beneath it read as two entries in the
    /// same flat list, and the pane stops appearing to have sections at all.
    static func groupHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

private extension NSViewController {
    /// Shows `alert` attached to this pane's window, and calls `handler` with
    /// what was clicked.
    ///
    /// A sheet rather than `runModal()`, which is what the guidelines ask for
    /// when the alert is about one window: a free-floating alert from an agent
    /// app can be dragged away from the window that raised it, or left behind
    /// it, and it blocks the whole app while it is up — including the status
    /// menu, which is the only way back into an app with no Dock icon.
    ///
    /// `runModal()` survives as the fallback for a controller not yet in a
    /// window. There is no window to attach to then, and an alert that silently
    /// does not appear is worse than one in the wrong place.
    func present(_ alert: NSAlert, then handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        guard let window = view.window else {
            handler?(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window) { handler?($0) }
    }

    /// The same, for the second sheet of a two-step exchange: ask, then report.
    ///
    /// Hopped to the next pass of the run loop because this is called from the
    /// first sheet's completion, and starting a second sheet from inside the
    /// dismissal of the first is asking AppKit to do two things to one window at
    /// once.
    func presentAfterSheet(_ alert: NSAlert) {
        DispatchQueue.main.async { [weak self] in self?.present(alert) }
    }
}
