//
//  BrightnessSlider.swift
//  EZDisplay
//
//  The brightness row in the status menu: one per display that macOS can dim.
//
//  Night Shift's warmth deliberately stayed out of the menu — it is set once and
//  a slider makes a menu tall. Brightness is the opposite: it is the control
//  people reach for most, and it belongs to one display rather than to the
//  machine, so the display's own section of the menu is where it can be found
//  without knowing which display is which.
//
//  Everything the row does goes through EZBrightness. There is no second dial
//  here: the same value the function keys move is the one this shows.
//

import AppKit

/// A slider that says when it is being dragged.
///
/// `NSSlider.mouseDown` runs its own tracking loop and does not return until the
/// drag ends, so bracketing the call is enough. The flag is what stops a
/// brightness notification arriving mid-drag — from the function keys, or from
/// the framework echoing this very slider — and yanking the knob out from under
/// the pointer.
private final class TrackingSlider: NSSlider {
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event)
        isTracking = false
    }
}

/// One display's brightness, as a menu row.
///
/// The item keeps the slider so the row can be brought up to date in place. A
/// change from anywhere else must not rebuild the menu the way the Night Shift
/// and True Tone observers do: the menu is open while this is on screen, and
/// rebuilding it would close it.
@objc final class BrightnessSliderItem: NSMenuItem {
    @objc let display: CGDirectDisplayID

    private let slider = TrackingSlider()
    private let readout = NSTextField(labelWithString: "")

    /// A row for `display`, or nil when macOS cannot set its brightness.
    ///
    /// Nil rather than a disabled row, which is the call the HDR item already
    /// makes: a menu is a list of things you can do, and a monitor driven by its
    /// own buttons is the ordinary case rather than a fault to report.
    @objc static func item(forDisplay display: CGDirectDisplayID) -> BrightnessSliderItem? {
        guard EZBrightness.available(forDisplay: display) else { return nil }
        let percent = EZBrightness.percent(forDisplay: display)
        guard percent >= 0 else { return nil }
        return BrightnessSliderItem(display: display, percent: percent)
    }

    private init(display: CGDirectDisplayID, percent: Int) {
        self.display = display
        // The title is never drawn — a view replaces everything AppKit would
        // have put here — but it is still what accessibility and type-select
        // read, so the row is not a nameless gap in the menu.
        super.init(title: "Brightness", action: nil, keyEquivalent: "")

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = Double(percent)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel("Brightness")
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        readout.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                        weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.translatesAutoresizingMaskIntoConstraints = false
        // Fixed and monospaced together, so the row does not shuffle sideways
        // as the number goes from one digit to three during a drag.
        readout.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let row = NSStackView(views: [icon, slider, readout])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        // Leading inset clears the gutter a menu leaves for state marks, so the
        // row lines up with the titles above it. The same 14 the colour rows use.
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 12)
        row.frame.size = row.fittingSize

        show(percent)
        view = row
    }

    required init(coder: NSCoder) { fatalError("not used") }

    // Not copyable, for the reason ColorModeMenuItem is not: NSMenuItem's copy
    // would allocate one of these without running init, leaving `display` and
    // the two subviews holding whatever was in the memory.
    override func copy(with zone: NSZone? = nil) -> Any {
        fatalError("BrightnessSliderItem cannot be copied; build a new one instead")
    }

    /// Brings the row up to date from the display, unless the user is mid-drag.
    ///
    /// The guard is against changes made *elsewhere*. A hand on the knob outranks
    /// the function keys, and letting a notification land mid-drag would yank the
    /// knob out from under the pointer.
    @objc func reload() {
        guard !slider.isTracking else { return }
        readAndShow()
    }

    /// The same, without the guard, for the row correcting itself.
    ///
    /// Reads the live value rather than taking one from the caller, because the
    /// notification says only that something moved and one observer serves every
    /// display. A read that fails leaves the row where it is: the alternative is
    /// a knob that jumps to zero because the display was asleep.
    private func readAndShow() {
        let percent = EZBrightness.percent(forDisplay: display)
        guard percent >= 0 else { return }
        slider.doubleValue = Double(percent)
        show(percent)
    }

    @objc private func moved(_ sender: NSSlider) {
        let percent = Int(sender.doubleValue.rounded())
        // Shown before the write, so the readout keeps up with the knob rather
        // than trailing a round trip behind it.
        show(percent)

        // A refused write puts the row back where the display actually is.
        // Without this the slider and the readout would both stand at a number
        // nothing accepted — the same optimistic write the phase 1 review found
        // in the Preferences warmth slider, and the very disagreement between
        // the slider and the keys this feature exists to avoid.
        // readAndShow rather than reload: the guard reload carries is against a
        // change from elsewhere arriving mid-drag, and this is the row's own
        // write, which is exactly when that guard is closed.
        if !EZBrightness.setPercent(percent, forDisplay: display) {
            readAndShow()
        }
    }

    private func show(_ percent: Int) {
        readout.stringValue = "\(percent)%"
        slider.setAccessibilityValueDescription("\(percent) percent")
    }
}
