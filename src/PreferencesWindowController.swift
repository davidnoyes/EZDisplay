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

    /// Posted when a menu-behavior pref changes, so the menu can rebuild.
    @objc static let changedNotification = Notification.Name("EZPrefsChanged")

    @objc static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showStandardKey:   true,
            showRefreshMenuKey: true,
            curatedCountKey:    6,
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

    // Resolved values for the ObjC++ menu builder — one source of truth for
    // defaults instead of raw NSUserDefaults reads with a duplicated fallback.
    @objc static func resolvedShowStandard() -> Bool { showStandard }
    @objc static func resolvedShowRefreshMenu() -> Bool { showRefreshMenu }
    @objc static func resolvedCuratedCount() -> Int { curatedCount }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

// MARK: - Colour-mode badge

/// A capsule holding one property of a colour mode. Tinted rather than plain,
/// because the point of the list is comparison and colour is what lets a row be
/// read at a glance instead of word by word.
private final class ColorBadge: NSView {
    private let tint: NSColor

    init(text: String, tint: NSColor, help: String) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        // Set on the badge alone. A tooltip is tracked per view and the label
        // covers all but a 6pt margin, so the label looked like it needed its
        // own — it does not: tested with the label's removed, and hovering the
        // text still tips.
        toolTip = help
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Repainted on every appearance change rather than tinted once at build
    // time: a CGColor is resolved against whichever appearance was current when
    // it was made, so a fill set in init keeps its light-mode value after a
    // switch to dark.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
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
    private var hdrFitMap: EZHDRFitMap?
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
        // A fourth column made the widths matter, and neither of these defaults
        // lets a declared width mean what it says. Left alone, the autoresizing
        // style spends the difference between the columns and the table on
        // whichever ones it likes — which is how "Refresh" came to read "Refr…"
        // while its neighbours kept the width they were given. And whatever the
        // widths, AppKit pads every column by a flat 17pt, so the table grows
        // past the 481pt it has to live in and the rightmost column loses its
        // tail: "HDR (DSC" with the bracket cut off. Measured, not derived —
        // `style = .plain` does not change it.
        //
        // So the budget is 481 less 17 a column: 413pt to divide between four.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Each width is the widest string its column can hold, plus a few points
        // for the cell's own inset: "3440 × 1440  ✓" is 97pt,
        // "Retina (HiDPI) · Native" 134, the "Refresh" header 55, and
        // "HDR (reduced)" 91.
        let resCol = NSTableColumn(identifier: .init("res"));   resCol.title = "Resolution"; resCol.width = 105
        let typeCol = NSTableColumn(identifier: .init("type")); typeCol.title = "Type";       typeCol.width = 146
        let hzCol = NSTableColumn(identifier: .init("hz"));     hzCol.title = "Refresh";      hzCol.width = 62
        // Resolution, refresh rate and HDR share one bandwidth budget, so this
        // belongs beside the two things that spend it rather than in the colour
        // list below — which only ever describes the timing already in force and
        // so cannot say what picking a different row would cost.
        let hdrCol = NSTableColumn(identifier: .init("hdr"));   hdrCol.title = "HDR";         hdrCol.width = 100
        tableView.addTableColumn(resCol)
        tableView.addTableColumn(typeCol)
        tableView.addTableColumn(hzCol)
        tableView.addTableColumn(hdrCol)
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
            modes = []; nativeW = 0; nativeH = 0; hdrFitMap = nil
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
        // After the native size, which it needs, and before the table reload
        // that reads it. Asked for on every reload rather than held: the map is
        // cached one layer down, on a key that carries the display's identity
        // and not its ID alone, so a swap for another display rebuilds and a
        // mere resolution change does not.
        hdrFitMap = EZHDRFitMap.map(forDisplay: selectedDisplayID,
                                     nativeWidth: Int32(nativeW), nativeHeight: Int32(nativeH))
        // Hidden outright when there is no map, rather than filled with a
        // thousand dashes. On the internal panel, which has no AV interface at
        // all, per-row uncertainty is the wrong story: the question does not
        // apply to the display, so the column should not be there to ask it.
        // Same judgement the colour-mode list makes about its own empty box.
        tableView.tableColumn(withIdentifier: .init("hdr"))?.isHidden = (hdrFitMap == nil)
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

        // The display reports its elements in its own order, which is neither
        // the order they were asked for nor one that means anything to a reader.
        // Sorted by picture quality instead, so the row worth having is the one
        // at the top. Ties keep the reported order, since sorted(by:) is not
        // stable and two rows swapping places between reloads would look like
        // the display had changed its mind.
        colorModes = EZColorModes.supported(forDisplay: selectedDisplayID)
            .enumerated()
            .sorted { a, b in
                let ra = qualityRank(a.element), rb = qualityRank(b.element)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
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
        if EZColorModes.supportsHDR(forDisplay: selectedDisplayID) {
            note += "\n•  Turn HDR on or off from the EZDisplay menu."
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
        if tableView === colorTable { return colorRow(colorModes[row]) }
        let m = modes[row]
        // Pixels, not points: a HiDPI mode is negotiated on the cable at its
        // backing size, so 2752 × 1152 Retina is a 5504 × 2304 signal.
        let pxW = Int((Float(m.width) * m.scale).rounded())
        let pxH = Int((Float(m.height) * m.scale).rounded())
        let text: String
        var help: String? = nil
        switch tableColumn?.identifier.rawValue {
        case "res":  text = "\(m.width) × \(m.height)" + (m.isCurrent ? "  ✓" : "")
        case "type":
            let isNative = nativeW > 0 && pxW == nativeW && pxH == nativeH
            text = (m.isHiDPI ? "Retina (HiDPI)" : "Standard") + (isNative ? " · Native" : "")
        case "hz":   text = m.refreshRate > 0 ? "\(m.refreshRate) Hz" : "—"
        case "hdr":
            let fit = hdrFitMap?.fit(forPixelWidth: Int32(pxW), height: Int32(pxH),
                                     refreshRate: Int32(m.refreshRate)) ?? .unknown
            // Blank for "no", a dash for "no answer" — the distinction, and the
            // reasoning behind it, live in +badgeForFit: so the menu tells the
            // same story. A dash appears on modes the private list reports and
            // CoreGraphics does not: 3440 × 1440 HiDPI at 50 Hz, say, whose
            // 6880 × 2880 signal matches no timing the display advertises and
            // has no native timing at that rate to fall back to.
            text = EZHDRFitMap.badge(for: fit) ?? ""
            help = EZHDRFitMap.explanation(for: fit)
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
        // Cleared as well as set: cells are recycled across columns and rows, so
        // a tooltip left behind would follow a reused cell into a column that
        // has nothing to explain. Set on the cell rather than its label — a
        // view's tooltip covers its subviews, so one here serves the whole cell.
        //
        // Hover only, unlike the help button above, and deliberately so. The
        // AXCell AppKit synthesises for a view-based row carries no AXHelp
        // attribute — measured; setAccessibilityHelp on the cell view is simply
        // dropped — and the alternative, folding the sentence into the cell's
        // AXDescription, would make VoiceOver read a paragraph on every row of
        // a thousand-row table. The badge itself is the information; this is
        // elaboration, and it is legible without it.
        cell.toolTip = help
        return cell
    }

    // MARK: Colour-mode rows

    /// Built fresh rather than recycled through `makeView(withIdentifier:)`: a
    /// row's badges vary in number and width, so a reused row would have to be
    /// torn down and rebuilt anyway, and the list is at most a couple of dozen
    /// rows on the timing in force.
    private func colorRow(_ mode: EZColorMode) -> NSView {
        let marker = NSImageView()
        marker.image = NSImage(systemSymbolName: mode.isCurrent ? "largecircle.fill.circle" : "circle",
                               accessibilityDescription: mode.isCurrent ? "Current mode" : nil)
        marker.contentTintColor = mode.isCurrent ? .controlAccentColor : .tertiaryLabelColor
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let depth = NSTextField(labelWithString: "\(mode.bitDepth)-bit")
        depth.font = NSFont.systemFont(ofSize: NSFont.systemFontSize,
                                       weight: mode.isCurrent ? .semibold : .regular)
        depth.toolTip = mode.bitDepth >= 10
            ? "\(mode.bitDepth) bits per color. Smoother gradients, and what HDR needs."
            : "8 bits per color. Gradients such as skies can show visible banding."
        depth.translatesAutoresizingMaskIntoConstraints = false
        // Fixed, so the badges start at the same x on every row and can be read
        // down the column instead of one row at a time.
        depth.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let row = NSStackView(views: [marker, depth] + badges(for: mode))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return row
    }

    /// One badge per property, tinted by whether that value is the full-fat
    /// option or a compromise the link had to make: green keeps everything,
    /// orange has given up chroma resolution, red has given up signal range.
    /// The transfer function is not a compromise either way, so HDR is called
    /// out in green and SDR stays neutral rather than being marked down.
    ///
    /// Derived from Apple's own enum names rather than the raw numbers, which
    /// are private and unversioned. An unrecognised name still shows, in
    /// neutral — better a badge reading something unexpected than a row that
    /// silently drops a property.
    private func badges(for mode: EZColorMode) -> [NSView] {
        var out: [NSView] = []

        let eotf = mode.eotfName
        if eotf.contains("2084") || eotf.uppercased().contains("PQ") {
            out.append(ColorBadge(text: "HDR10", tint: .systemGreen,
                                  help: "High Dynamic Range. Brighter highlights and deeper "
                                      + "shadows, in content that was made for it."))
        } else if eotf.uppercased().contains("HLG") {
            out.append(ColorBadge(text: "HLG", tint: .systemGreen,
                                  help: "Hybrid Log-Gamma, a broadcast flavor of HDR. "
                                      + "Rarely what you want on a computer display."))
        } else {
            out.append(ColorBadge(text: "SDR", tint: .systemGray,
                                  help: "Standard Dynamic Range — ordinary brightness. "
                                      + "The right choice for everyday desktop work."))
        }

        // "RGB 4:4:4" and "YCbCr 4:2:2" split into the encoding and the chroma
        // sampling, because they are two separate things to compare and only
        // one of them is present on every mode.
        let parts = mode.pixelEncodingName.split(separator: " ", maxSplits: 1).map(String.init)
        if let encoding = parts.first {
            let name = encoding.uppercased()
            let isRGB = name == "RGB"
            // Three cases, not two. The name comes from a private enum-to-string
            // helper that falls back to a bare number, and a tooltip that says
            // what a mode *does* must not say it about a value it did not
            // recognise. Anything unmatched gets the neutral sentence.
            let help: String
            if isRGB {
                help = "Every pixel carries its own full color. Best for text and fine detail."
            } else if name.hasPrefix("YCBCR") || name.hasPrefix("YUV") {
                help = "Color sent as brightness plus two color channels, so it can be "
                     + "thinned to save cable bandwidth."
            } else {
                help = "Pixel encoding the display reports for this mode."
            }
            out.append(ColorBadge(text: encoding,
                                  tint: isRGB ? .systemGreen : .systemOrange,
                                  help: help))
        }
        if parts.count > 1 {
            // "4:2:2 (DP tunneling)" -> "4:2:2". The parenthetical is how the
            // signal is carried, not what the colour is, and spelling it out
            // made this the one badge wide enough to push the row past the
            // column. It survives in the tooltip.
            let raw = parts[1]
            let sampling = raw.split(separator: "(").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
            let full = sampling.hasPrefix("4:4:4")
            let carried = raw.lowercased().contains("tunnel")
                ? " Carried by DisplayPort tunneling over USB-C or Thunderbolt."
                : ""
            out.append(ColorBadge(text: sampling,
                                  tint: full ? .systemGreen : .systemOrange,
                                  help: (full
                                      ? "No color thinning. Text stays sharp."
                                      : "Color detail is halved or quartered to fit the cable. "
                                        + "Fine text can look fringed or smeared.") + carried))
        }

        switch mode.dynamicRangeName.lowercased() {
        case "full":
            out.append(ColorBadge(text: "Full Range", tint: .systemGreen,
                                  help: "Uses the whole black-to-white scale. Correct for a "
                                      + "computer display."))
        case "limited":
            out.append(ColorBadge(text: "Limited Range", tint: .systemRed,
                                  help: "Uses the narrower TV scale. On a monitor this shows as "
                                      + "washed-out blacks and flat contrast."))
        default:
            out.append(ColorBadge(text: mode.dynamicRangeName, tint: .systemGray,
                                  help: "Signal range reported by the display."))
        }

        // "BT.2020 (RGB)" -> "BT.2020": the parenthetical repeats the encoding
        // badge two along, and the row has better uses for the width.
        let colorimetry = mode.colorimetryName.split(separator: "(").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? mode.colorimetryName
        if !colorimetry.isEmpty {
            out.append(ColorBadge(text: colorimetry, tint: .systemGray,
                                  help: colorimetryHelp(colorimetry)))
        }

        // Packed in with the rest rather than pushed to the trailing edge by a
        // spacer. The spacer opened a gap the width of the row and put this
        // badge exactly where a row that overflows loses its last item.
        if mode.isDerived {
            out.append(ColorBadge(text: "Derived", tint: .systemPurple,
                                  help: "Added by the driver — the display does not advertise "
                                      + "this combination itself."))
        }
        return out
    }

    /// Colorimetry is the one badge whose name means nothing to a reader who
    /// does not already know it, so each gets a sentence rather than a gloss of
    /// the acronym. Matched on a prefix: the display reports compound names
    /// such as "SMPTE 170M/BT.601".
    private func colorimetryHelp(_ name: String) -> String {
        let n = name.uppercased()
        if n.hasPrefix("BT.2020") || n.hasPrefix("REC.2020") {
            return "Wide color range used by HDR. Shows deeper reds and greens than sRGB."
        }
        if n.hasPrefix("BT.709") || n.hasPrefix("REC.709") {
            return "The standard HD video color range, near enough identical to sRGB."
        }
        if n.hasPrefix("SRGB") || n.hasPrefix("DEFAULT") {
            return "The ordinary computer color range. What most content is made for."
        }
        if n.hasPrefix("DCI") || n.hasPrefix("P3") {
            return "Digital-cinema color range. Wider than sRGB, narrower than BT.2020."
        }
        if n.hasPrefix("SMPTE") || n.hasPrefix("BT.601") {
            return "An old standard-definition video color range. Colors can look shifted "
                 + "on a modern display."
        }
        return "Color range the display reports for this mode."
    }

    /// Sort key for the list, best first. It is compared as a tuple, so the
    /// order of the fields *is* the priority, and every field is "lower is
    /// better" so the whole thing sorts ascending.
    ///
    /// HDR first, because it is the thing being chosen. Everything below it
    /// ranks by what the compromise costs on a computer display: thinned chroma
    /// smears every line of text, Limited Range washes out every black, and bit
    /// depth shows up only in gradients. Encoding and then colorimetry sort
    /// last — between two rows already equal on chroma, RGB against YCbCr is a
    /// difference in name more than in picture, and colorimetry only separates
    /// rows identical in every other way.
    ///
    /// Putting the transfer function on top means a 12-bit HDR 4:2:2 mode
    /// outranks an 8-bit SDR 4:4:4 one, which is the intended reading: the list
    /// answers "which HDR mode is best" before it answers "which mode is
    /// sharpest". The badges still say what each row gives up.
    ///
    /// A value the name-matching does not recognise sorts to the bottom of its
    /// own field rather than the top, for the same reason the badges stay
    /// neutral on one: an unknown is not a promise of quality.
    private func qualityRank(_ mode: EZColorMode) -> (Int, Int, Int, Int, Int, Int) {
        let parts = mode.pixelEncodingName.split(separator: " ", maxSplits: 1).map(String.init)
        let encoding = (parts.first ?? "").uppercased()
        let sampling = parts.count > 1 ? parts[1] : ""

        // RGB names no sampling because it cannot be thinned; that is 4:4:4 by
        // definition, not a missing value.
        let chroma: Int
        if sampling.hasPrefix("4:4:4") || (sampling.isEmpty && encoding == "RGB") { chroma = 0 }
        else if sampling.hasPrefix("4:2:2") { chroma = 1 }
        else if sampling.hasPrefix("4:2:0") { chroma = 2 }
        else { chroma = 3 }

        let range: Int
        switch mode.dynamicRangeName.lowercased() {
        case "full":    range = 0
        case "limited": range = 1
        default:        range = 2
        }

        let eotf = mode.eotfName.uppercased()
        let transfer: Int
        if eotf.contains("2084") || eotf.contains("PQ") { transfer = 0 }
        else if eotf.contains("HLG") { transfer = 1 }
        // SDR is a recognised answer and an unrecognised one is not, so they get
        // separate buckets even though both sort below HDR. Sharing a bucket
        // would put an unknown transfer function level with plain SDR, which is
        // a claim about it that the name-matching has not earned.
        else if eotf.contains("GAMMA") || eotf.contains("SDR") || eotf.contains("SRGB") { transfer = 2 }
        else { transfer = 3 }

        let n = mode.colorimetryName.uppercased()
        let gamut: Int
        if n.hasPrefix("BT.2020") || n.hasPrefix("REC.2020") { gamut = 0 }
        else if n.hasPrefix("DCI") || n.hasPrefix("P3") { gamut = 1 }
        else if n.hasPrefix("BT.709") || n.hasPrefix("REC.709")
                 || n.hasPrefix("SRGB") || n.hasPrefix("DEFAULT") { gamut = 2 }
        else { gamut = 3 }

        return (transfer, chroma, range, -Int(mode.bitDepth), encoding == "RGB" ? 0 : 1, gamut)
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

    /// Switches the display to the selected colour mode, behind confirm-or-revert.
    ///
    /// This restarts the display link, so the picture goes black for a moment in
    /// each direction — which is exactly why it belongs behind SafeApply rather
    /// than being applied outright. Reverting is the same call with the previous
    /// mode, so the undo is as reliable as the change.
    @objc private func applySelectedColorMode() {
        let display = selectedDisplayID
        let row = colorTable.selectedRow
        guard display != 0, row >= 0, row < colorModes.count else { return }
        let mode = colorModes[row]
        // Double-click reaches here regardless of the button's state, so the
        // no-op case is re-checked rather than assumed away.
        guard !mode.isCurrent else { return }

        let elementID = mode.elementID
        let label = mode.label

        SafeApply.onApplyQueue {
            let restorePoint = EZColorModes.applyElementID(elementID, toDisplay: display)
            // nil covers two situations that deserve opposite responses, and
            // only the hardware can tell them apart. The row list is a
            // snapshot — re-read three seconds after a screen change, and not
            // at all when something outside EZDisplay moves the link — so the display
            // being on the wanted mode already is a live possibility, and it is
            // not a fault. Ask before accusing.
            let alreadyThere = restorePoint == nil
                && EZColorModes.current(forDisplay: display)?.elementID == elementID

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let restorePoint = restorePoint else {
                    // Deliberately does not promise nothing changed. Most ways
                    // of getting here never reach the hardware at all, but one
                    // does: StartLink can be called and come back non-zero,
                    // and what the link is running after that is not something
                    // to guess at. Point at the refreshed list instead.
                    if !alreadyThere { self.reportColorModeProblem(
                        "That color mode could not be applied.",
                        "The display would not switch to it, or it is no longer one this "
                        + "display offers at the resolution and refresh rate in force now. "
                        + "The list has been refreshed to show what it is running.") }
                    self.reloadColorMode()
                    return
                }

                // The link takes a moment to settle, same as HDR.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.reloadColorMode()
                }

                SafeApply.confirm(title: "Keep this color mode?",
                                  detail: "\(label). The display blanks for a moment each time "
                                        + "the link restarts.") { [weak self] in
                    SafeApply.onApplyQueue {
                        let result = EZColorModes.restore(restorePoint)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self?.reloadColorMode()
                            // Superseded is silent on purpose: the timing moved
                            // and macOS picked a colour element for it, which is
                            // the right outcome and not EZDisplay's to undo. Failed is
                            // the opposite — the panel has just told the user it
                            // was putting things back, and it did not.
                            //
                            // Except when the display has been unplugged, which
                            // reports Failed for the honest reason that there is
                            // no link left to restart. Both sentences would then
                            // be false and the advice unfollowable, since the
                            // list is hidden for a display that is not there —
                            // and an unplug drops the applied mode anyway, so
                            // there is nothing left to put right.
                            if result == .failed && CGDisplayIsOnline(display) != 0 {
                                self?.reportColorModeProblem(
                                    "The previous color mode could not be restored.",
                                    "The display is still on the mode that was just applied. "
                                    + "Pick the mode you want from the list and apply it again.")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Both colour-mode faults report the same way: a sheet on the Preferences
    /// window, or a modal if it has gone. Neither is a state the user can be left
    /// to infer — one is a click that did nothing, the other is a display left
    /// somewhere they did not put it.
    private func reportColorModeProblem(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

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
