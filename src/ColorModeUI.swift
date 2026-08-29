//
//  ColorModeUI.swift
//  EZDisplay
//
//  How a colour mode is presented, and how one gets applied — in one place,
//  because it is now presented twice. Preferences lists the modes in a table and
//  the status menu lists them in a submenu, and the two have to agree: the same
//  rows, in the same order, with the same badges meaning the same things. Two
//  copies of that would drift, and a badge that means one thing in a window and
//  another in a menu is worse than no badge.
//
//  Everything here is layout and wording. What a mode *is* lives in ColorMode.h,
//  and applying one goes through SafeApply exactly as a resolution change does.
//

import AppKit

// MARK: - Badge

/// A capsule holding one property of a colour mode. Tinted rather than plain,
/// because the point of the list is comparison and colour is what lets a row be
/// read at a glance instead of word by word.
final class ColorBadge: NSView {
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

// MARK: - Menu item

/// A menu item standing for one colour mode, carrying the mode and the display
/// it belongs to so the action does not have to work either out again. Same
/// shape as ResMenuItem, for the same reason: the menu is rebuilt on every open
/// and an item has to be self-contained.
@objc class ColorModeMenuItem: NSMenuItem {
    @objc let mode: EZColorMode
    @objc let display: CGDirectDisplayID

    init(mode: EZColorMode, display: CGDirectDisplayID, action: Selector) {
        self.mode = mode
        self.display = display
        super.init(title: "", action: action, keyEquivalent: "")
    }

    required init(coder: NSCoder) { fatalError("not used") }

    // ResMenuItem carries its fields across a copy by hand, because copying is
    // how the resolution menus are built. These items are never copied — they
    // are made fresh each time the submenu opens — and NSMenuItem's copy would
    // allocate one of these without running init, leaving `mode` and `display`
    // holding whatever was in the memory. Fail where the mistake is made rather
    // than somewhere downstream that reads the wreckage.
    override func copy(with zone: NSZone? = nil) -> Any {
        fatalError("ColorModeMenuItem cannot be copied; build a new one instead")
    }
}

/// The "Color Mode" item itself, which exists only to own its loader: an
/// NSMenu holds its delegate weakly, so something has to keep it alive, and the
/// item is what the submenu's lifetime already follows.
private final class ColorModeSubmenuItem: NSMenuItem {
    let loader: ColorModeMenuLoader

    init(display: CGDirectDisplayID, target: AnyObject?, action: Selector) {
        loader = ColorModeMenuLoader(display: display, target: target, action: action)
        super.init(title: "Color Mode", action: nil, keyEquivalent: "")
    }

    required init(coder: NSCoder) { fatalError("not used") }

    // Not copyable, for the reason ColorModeMenuItem is not — and worse here,
    // since a copy would have no loader, so its submenu's delegate would be nil
    // and it would open empty every time with nothing to say why.
    override func copy(with zone: NSZone? = nil) -> Any {
        fatalError("ColorModeSubmenuItem cannot be copied; build a new one instead")
    }
}

/// Fills the submenu in as it opens. See `EZColorModeUI.menuItem` for why the
/// work waits until then.
private final class ColorModeMenuLoader: NSObject, NSMenuDelegate {
    private let display: CGDirectDisplayID
    private weak var target: AnyObject?
    private let action: Selector

    init(display: CGDirectDisplayID, target: AnyObject?, action: Selector) {
        self.display = display
        self.target = target
        self.action = action
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        EZColorModeUI.populate(menu, forDisplay: display, target: target, action: action)
    }
}

/// The row drawn inside a `ColorModeMenuItem`.
///
/// A menu item with a custom view gives up everything AppKit would otherwise do
/// for it, so both of those things are put back here: the highlight that follows
/// the pointer, and the click that fires the action. Neither is optional — a row
/// that never lights up looks disabled, and one that swallows the click looks
/// broken.
///
/// The highlight is deliberately the unemphasized selection material rather than
/// the accent fill a plain menu item uses. An accent fill would leave every
/// badge tint sitting on saturated blue, so the row would have to recolour
/// itself on hover to stay legible; the grey keeps all six badges reading the
/// same as they do in Preferences, which is the whole point of sharing them.
private final class ColorModeMenuRow: NSView {
    private let highlight = NSVisualEffectView()

    init(content: NSView) {
        super.init(frame: .zero)

        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = false
        highlight.blendingMode = .behindWindow
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            // Inset to match the rounded highlight AppKit draws for an ordinary
            // item, which stops short of the menu's own edges.
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // isHighlighted is the source of truth rather than the pointer, so a row
    // reached with the arrow keys lights up too. The tracking area only says
    // when to look again.
    override func viewWillDraw() {
        super.viewWillDraw()
        highlight.isHidden = !(enclosingMenuItem?.isHighlighted ?? false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { needsDisplay = true }

    // A custom view keeps the mouse to itself, so the item's action has to be
    // sent by hand. The menu is dismissed first and the action sent after it has
    // gone, because applying a mode puts a confirmation panel on screen and a
    // panel behind an open menu cannot be answered.
    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        menu.cancelTracking()
        DispatchQueue.main.async { menu.performActionForItem(at: index) }
    }
}

// MARK: - Shared presentation

@objc class EZColorModeUI: NSObject {

    /// The modes a display offers at its current timing, in the order both the
    /// table and the menu show them.
    ///
    /// The display reports its elements in its own order, which is neither the
    /// order they were asked for nor one that means anything to a reader. Sorted
    /// by picture quality instead, so the row worth having is the one at the
    /// top. Ties keep the reported order, since sorted(by:) is not stable and
    /// two rows swapping places between reloads would look like the display had
    /// changed its mind.
    @objc static func sortedModes(forDisplay display: CGDirectDisplayID) -> [EZColorMode] {
        EZColorModes.supported(forDisplay: display)
            .enumerated()
            .sorted { a, b in
                let ra = qualityRank(a.element), rb = qualityRank(b.element)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    /// A "Color Mode" item for the status menu, whose submenu fills itself in
    /// when it is about to open.
    ///
    /// Late rather than with the rest of the menu, and the second reason is the
    /// one that matters. Reading the modes costs about four hundred milliseconds
    /// of IOKit work, too much to spend on every rebuild of a submenu the user
    /// may never open. And the answer goes stale in a way nothing tells the app
    /// about: a display that has gone to sleep reports no modes at all, and
    /// across a full display sleep and wake macOS posted neither a
    /// reconfiguration callback nor a workspace screen notification — measured,
    /// not assumed. A list built at the wrong moment would therefore stay empty
    /// until something unrelated rebuilt the menu. Built as it opens, it is read
    /// at the one moment the display is certainly awake.
    ///
    /// The item is always offered for a display that could have modes, because
    /// deciding otherwise means making the expensive call to find out. What it
    /// costs when the answer turns out to be nothing is one disabled line saying
    /// so, which is better than the alternative reading of a missing item: that
    /// EZDisplay has no such feature.
    @objc static func menuItem(forDisplay display: CGDirectDisplayID,
                               target: AnyObject?,
                               action: Selector) -> NSMenuItem {
        let item = ColorModeSubmenuItem(display: display, target: target, action: action)
        let submenu = NSMenu(title: "")
        submenu.delegate = item.loader
        item.submenu = submenu
        return item
    }

    /// Fills `menu` with one row per mode. Separated from the item so the work
    /// happens on open, and so the empty case has somewhere to say so.
    fileprivate static func populate(_ menu: NSMenu,
                                     forDisplay display: CGDirectDisplayID,
                                     target: AnyObject?,
                                     action: Selector) {
        menu.removeAllItems()

        let modes = sortedModes(forDisplay: display)
        guard !modes.isEmpty else {
            // Says which of the two it is. A display reports nothing here either
            // because EZDisplay cannot reach its link at all, or because it can
            // and the display named no modes — and the user can tell those apart
            // from the screen in front of them far better than this can.
            let none = NSMenuItem(title: "No color modes reported", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }

        for mode in modes {
            let item = ColorModeMenuItem(mode: mode, display: display, action: action)
            item.target = target
            // Leading inset clears the gutter a menu leaves for state marks, so
            // the rows line up with the titles of the items above them.
            let row = ColorModeMenuRow(content: colorRow(mode, leadingInset: 14))
            row.frame.size = row.fittingSize
            // A view replaces everything AppKit would have drawn, and the title
            // goes undrawn with it — but it is still what accessibility and
            // type-select read, and without it the submenu is sixteen unnamed
            // rows. Set on the item as well as the view, because the item is
            // what a menu reader asks.
            //
            // The one-line label rather than the badges: those are an
            // abbreviation that only works read side by side. The running row
            // says so in words, since that is all the filled marker means and a
            // marker cannot be read aloud.
            let spoken = mode.isCurrent ? "\(mode.label), current" : mode.label
            item.title = spoken
            row.setAccessibilityRole(.menuItem)
            row.setAccessibilityLabel(spoken)
            item.view = row
            menu.addItem(item)
        }
    }

    /// Switches the display to `mode`, behind confirm-or-revert.
    ///
    /// This restarts the display link, so the picture goes black for a moment in
    /// each direction — which is exactly why it belongs behind SafeApply rather
    /// than being applied outright. Reverting is the same call with the previous
    /// mode, so the undo is as reliable as the change.
    ///
    /// `window` is where a problem gets reported, as a sheet; the menu has no
    /// window and gets a modal instead. `onSettle` runs a second after the link
    /// has been asked to move, for a caller with a list to re-read.
    @objc static func apply(_ mode: EZColorMode,
                            toDisplay display: CGDirectDisplayID,
                            in window: NSWindow?,
                            onSettle: (() -> Void)?) {
        // Double-click and a menu click both reach here regardless of any
        // button's state, so the no-op case is re-checked rather than assumed
        // away.
        guard display != 0, !mode.isCurrent else { return }

        let elementID = mode.elementID
        let label = mode.label

        SafeApply.onApplyQueue {
            let restorePoint = EZColorModes.applyElementID(elementID, toDisplay: display)
            // nil covers two situations that deserve opposite responses, and
            // only the hardware can tell them apart. The row list is a
            // snapshot — re-read three seconds after a screen change, and not
            // at all when something outside EZDisplay moves the link — so the
            // display being on the wanted mode already is a live possibility,
            // and it is not a fault. Ask before accusing.
            let alreadyThere = restorePoint == nil
                && EZColorModes.current(forDisplay: display)?.elementID == elementID

            DispatchQueue.main.async {
                guard let restorePoint = restorePoint else {
                    // Deliberately does not promise nothing changed. Most ways
                    // of getting here never reach the hardware at all, but one
                    // does: StartLink can be called and come back non-zero,
                    // and what the link is running after that is not something
                    // to guess at. Point at the refreshed list instead.
                    if !alreadyThere {
                        report("That color mode could not be applied.",
                               "The display would not switch to it, or it is no longer one this "
                               + "display offers at the resolution and refresh rate in force now. "
                               + "The list has been refreshed to show what it is running.",
                               in: window)
                    }
                    onSettle?()
                    return
                }

                // The link takes a moment to settle, same as HDR.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onSettle?() }

                SafeApply.confirm(title: "Keep this color mode?",
                                  detail: "\(label). The display blanks for a moment each time "
                                        + "the link restarts.") {
                    SafeApply.onApplyQueue {
                        let result = EZColorModes.restore(restorePoint)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            onSettle?()
                            // Superseded is silent on purpose: the timing moved
                            // and macOS picked a colour element for it, which is
                            // the right outcome and not EZDisplay's to undo.
                            // Failed is the opposite — the panel has just told
                            // the user it was putting things back, and it did
                            // not.
                            //
                            // Except when the display has been unplugged, which
                            // reports Failed for the honest reason that there is
                            // no link left to restart. Both sentences would then
                            // be false and the advice unfollowable, since the
                            // list is hidden for a display that is not there —
                            // and an unplug drops the applied mode anyway, so
                            // there is nothing left to put right.
                            if result == .failed && CGDisplayIsOnline(display) != 0 {
                                report("The previous color mode could not be restored.",
                                       "The display is still on the mode that was just applied. "
                                       + "Pick the mode you want from the list and apply it again.",
                                       in: window)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Both colour-mode faults report the same way: a sheet on the window that
    /// asked, or a modal when there is none. Neither is a state the user can be
    /// left to infer — one is a click that did nothing, the other is a display
    /// left somewhere they did not put it.
    private static func report(_ message: String, _ detail: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Rows and badges

    /// Built fresh rather than recycled through `makeView(withIdentifier:)`: a
    /// row's badges vary in number and width, so a reused row would have to be
    /// torn down and rebuilt anyway, and the list is at most a couple of dozen
    /// rows on the timing in force.
    static func colorRow(_ mode: EZColorMode, leadingInset: CGFloat = 4) -> NSView {
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
        row.edgeInsets = NSEdgeInsets(top: 0, left: leadingInset, bottom: 0, right: leadingInset)
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
    private static func badges(for mode: EZColorMode) -> [NSView] {
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
    private static func colorimetryHelp(_ name: String) -> String {
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
    private static func qualityRank(_ mode: EZColorMode) -> (Int, Int, Int, Int, Int, Int) {
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
}
