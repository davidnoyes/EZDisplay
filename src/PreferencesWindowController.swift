//
//  PreferencesWindowController.swift
//  EZDisplay
//
//  Programmatic Preferences window: a per-display mode table plus menu-behavior
//  toggles. Built in code (not the storyboard) so it is self-contained and
//  reviewable. Menu-behavior prefs live in UserDefaults and are read by the
//  ObjC++ menu builder in EZAppDelegate.mm.
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
        ])
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
        let vc = PreferencesViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = "EZDisplay Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // A lower bound, not the final height: the content's own constraints
        // grow the window past this. Deliberately under-declared, so the window
        // still fits its content on an older macOS where the login-item
        // checkbox below is absent.
        window.setContentSize(NSSize(width: 540, height: 700))
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

// MARK: - View controller

class PreferencesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nativeLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let curatedStepper = NSStepper()
    private let curatedLabel = NSTextField(labelWithString: "")
    private let warmthSlider = NSSlider()
    private let warmthLabel = NSTextField(labelWithString: "")
    private let schedulePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scheduleFrom = NSDatePicker()
    private let scheduleTo = NSDatePicker()
    private var scheduleWindowRow: NSStackView?
    private var launchAtLoginCheck: NSButton?
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
        // The active mode may have changed since the window was last shown.
        reloadModes()
        reloadWarmth()
        reloadSchedule()
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
        // Neither default lets a declared width mean what it says. Left alone,
        // the autoresizing style spends the difference between the columns and
        // the table on whichever ones it likes — which is how "Refresh" came to
        // read "Refr…" while its neighbours kept the width they were given. And
        // whatever the widths, AppKit pads every column by a flat 17pt, so a
        // table whose columns sum to its own width overflows and the rightmost
        // one loses its tail. Measured, not derived — `style = .plain` does not
        // change it.
        //
        // So the budget is 481 less 17 a column: 430pt to divide between three.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Each column holds its widest string with room to spare — "3440 × 1440  ✓"
        // is 97pt and "Retina (HiDPI) · Native" 134 — and the three add up to the
        // budget exactly, so nothing overflows and no gap is left at the edge.
        let resCol = NSTableColumn(identifier: .init("res"));   resCol.title = "Resolution"; resCol.width = 130
        let typeCol = NSTableColumn(identifier: .init("type")); typeCol.title = "Type";       typeCol.width = 200
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
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // 216, not 240: the colour-mode section below costs the height of a
        // second list, and the window has to stay inside the 775pt a 1280×800
        // screen leaves it.
        scroll.heightAnchor.constraint(equalToConstant: 216).isActive = true

        let applyButton = NSButton(title: "Apply Selected Resolution", target: self, action: #selector(applySelected))

        // Colour mode: one writable control, the mode list. What the display
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
        // The scroll view spans the stack's 500pt, less 1pt of bezel each side.
        // The vertical scroller's gutter comes off that too: it is an overlay
        // on most Macs and costs nothing, but under "always show scroll bars"
        // it is real, and a row sized to the full width puts its last badge
        // behind it. Reserved either way — 15pt of slack is cheaper than a
        // clipped badge in a window that cannot be resized or scrolled
        // sideways.
        let colorCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        colorCol.width = 498 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        colorCol.minWidth = colorCol.width
        colorTable.addTableColumn(colorCol)
        colorTable.dataSource = self
        colorTable.delegate = self
        colorScroll.documentView = colorTable
        colorScroll.hasVerticalScroller = true
        colorScroll.borderType = .bezelBorder
        colorScroll.translatesAutoresizingMaskIntoConstraints = false
        // Kept short deliberately: the window is not resizable and has no outer
        // scroll, so every point added here is a point closer to overflowing a
        // small screen. The list scrolls internally instead.
        colorScroll.heightAnchor.constraint(equalToConstant: 108).isActive = true

        // Options
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

        // Night Shift warmth, which is here rather than in the menu because it
        // is one value on a scale: a menu can carry the on and off the status
        // menu already shows, and not this. The section is absent altogether on
        // a Mac that cannot do Night Shift, the way the HDR item is.
        var nightShiftViews: [NSView] = []
        if EZNightShift.supported() {
            warmthSlider.minValue = 0
            warmthSlider.maxValue = 100
            reloadWarmth()
            warmthSlider.target = self
            warmthSlider.action = #selector(warmthChanged)
            // Continuous, so the tint follows the knob. Each step writes the
            // value straight through, which is what makes the preview live.
            // Committing every step rather than only on release was measured
            // before it was kept: 220 committed writes, a full drag of this
            // slider, take 2.1 ms in total, and are indistinguishable from
            // uncommitted ones. The daemon coalesces, so there is no per-step
            // disk write to avoid and no reason to carry a commit flag around.
            warmthSlider.isContinuous = true
            warmthSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true

            let warmthRow = NSStackView(views: [warmthLabel, warmthSlider])
            warmthRow.orientation = .horizontal
            warmthRow.alignment = .centerY
            warmthRow.spacing = 8

            // Which schedule the menu's Scheduled item runs. The menu offers the
            // three states because they are one exclusive choice a click can
            // make; this is the setting behind one of them, and it is a setting
            // rather than a state — it keeps its value while Night Shift is off,
            // which is the whole reason it is not in the menu.
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

            nightShiftViews = [NSBox.separator(),
                               NSTextField(labelWithString: "Night Shift"),
                               warmthRow, scheduleRow, windowRow]
        }

        // Bottom action buttons
        let editButton = NSButton(title: "Edit Custom Resolutions…", target: self, action: #selector(editCustom))
        let restoreButton = NSButton(title: "Restore Defaults…", target: self, action: #selector(restoreDefaults))
        let restoreAllButton = NSButton(title: "Restore All Displays…", target: self, action: #selector(restoreAllDefaults))
        let bottomRow = NSStackView(views: [editButton, restoreButton, restoreAllButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12

        let colorHeaderRow = NSStackView(views: [NSTextField(labelWithString: "Color mode"),
                                                 colorHelpButton])
        colorHeaderRow.orientation = .horizontal
        colorHeaderRow.alignment = .centerY
        colorHeaderRow.spacing = 6

        let stack = NSStackView(views: [displayRow, nativeLabel, scroll, applyButton,
                                        NSBox.separator(), colorHeaderRow,
                                        colorStatusLabel, colorScroll,
                                        colorApplyButton,
                                        NSBox.separator(), NSTextField(labelWithString: "Menu options")] + optionViews +
                                       nightShiftViews +
                                       [NSBox.separator(), bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            colorScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            colorScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    private func checkbox(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        return b
    }

    private func updateCuratedLabel() {
        curatedLabel.stringValue = "Recommended list length: \(curatedStepper.integerValue)"
    }

    private func updateWarmthLabel() {
        warmthLabel.stringValue = "Warmth: \(warmthSlider.integerValue)%"
    }

    /// Puts the slider back on the live warmth. The value belongs to the system
    /// rather than to this window, so anything else — the command line, System
    /// Settings — can move it while the window is closed.
    @objc private func reloadWarmth() {
        guard EZNightShift.supported() else { return }
        // -1 means the daemon would not answer. Nothing can be shown for that,
        // so the slider sits at the cool end rather than at a number nobody set.
        warmthSlider.integerValue = max(0, EZNightShift.warmthPercent())
        updateWarmthLabel()
    }

    /// Puts the schedule controls back on what is really set, the way
    /// `reloadWarmth` does: the command line and System Settings can both move
    /// this while the window is closed.
    @objc private func reloadSchedule() {
        guard EZNightShift.supported() else { return }

        // Sunset to sunrise is dropped rather than disabled where location
        // services are off, which is what System Settings does. A greyed row
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
        // The valid colour modes depend on the timing in force, so this belongs
        // with the mode reload rather than only with the display picker.
        reloadColorMode()
    }

    /// Colour mode is read through a private, unversioned API that only covers
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
        // because the ranking is a judgement and an unexplained one looks like a
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
    /// is the state the window opens in. Saying so with a greyed-out button beats
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
        // One delegate serves both tables; only the colour list has a button
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

    /// Shows the colour-mode explanation in a popover, for readers who cannot
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

    /// Switches the display to the selected colour mode. The apply itself, and
    /// the confirm-or-revert around it, are shared with the status menu's
    /// picker — one route to the hardware, so one thing to get right.
    @objc private func applySelectedColorMode() {
        let row = colorTable.selectedRow
        guard row >= 0, row < colorModes.count else { return }
        EZColorModeUI.apply(colorModes[row],
                            toDisplay: selectedDisplayID,
                            in: view.window) { [weak self] in self?.reloadColorMode() }
    }

    @objc private func toggleShowStandard(_ sender: NSButton) { EZPrefs.showStandard = (sender.state == .on) }
    @objc private func toggleShowRefresh(_ sender: NSButton)  { EZPrefs.showRefreshMenu = (sender.state == .on) }

    @objc private func curatedChanged() {
        EZPrefs.curatedCount = curatedStepper.integerValue
        updateCuratedLabel()
    }

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
            a.runModal()
        }
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
        let confirm = NSAlert()
        confirm.messageText = "Restore default settings for \(name)?"
        confirm.informativeText = "This removes EZDisplay's custom resolution overrides for this display. A reboot may be required to fully apply."
        confirm.addButton(withTitle: "Restore")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let item = RestoreSettingsItem(title: "", action: #selector(restoreDefaults),
                                       vendorID: CGDisplayVendorNumber(selectedDisplayID),
                                       productID: CGDisplayModelNumber(selectedDisplayID),
                                       displayName: name)
        let result = NSAlert()
        if let error = item.restoreSettings() {
            result.messageText = (error["NSAppleScriptErrorBriefMessage"] as? String) ?? "Restore failed."
            result.alertStyle = .critical
        } else {
            result.messageText = "Restore complete."
        }
        result.runModal()
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
            empty.runModal()
            return
        }

        let plural = paths.count == 1 ? "display" : "displays"
        let confirm = NSAlert()
        confirm.messageText = "Restore default settings for all displays?"
        confirm.informativeText = "This removes the custom resolution overrides EZDisplay created for \(paths.count) \(plural) from \(CustomResolutionsStore.rootdir), including displays that are not currently connected. A reboot may be required to fully apply.\(othersNote)"
        confirm.addButton(withTitle: "Restore All")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = NSAlert()
        if let error = RestoreSettingsItem.restoreAllSettings() {
            result.messageText = (error["NSAppleScriptErrorBriefMessage"] as? String) ?? "Restore failed."
            result.alertStyle = .critical
        } else {
            result.messageText = "Restore complete."
        }
        result.runModal()
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
