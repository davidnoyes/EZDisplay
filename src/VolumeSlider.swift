//
//  VolumeSlider.swift
//  EZDisplay
//
//  The volume row in the status menu: one per display with speakers of its own.
//
//  Modeled on BrightnessSlider, and different from it in the one way that
//  matters. Brightness goes through a native call that returns in microseconds,
//  so the row can write on every tick of a drag. Volume goes over DDC/CI, where
//  a write is two frames on an I2C bus and the read-back that follows it costs
//  50 ms of settle time. Writing that on every tick would put hundreds of frames
//  onto the bus during one drag.
//
//  So this row does write on every tick, and the coalescing happens one layer
//  down: `setPercentCoalesced:` keeps only the newest value and drops a write
//  for a value already sent. Coalescing there rather than behind a timer here
//  is what keeps the bus from getting in front of a redraw — the writes drain
//  on their own queue while the knob keeps up with the mouse.
//
//  This dial belongs to the monitor, not to macOS. It is not the output volume
//  in Sound settings and moving one does not move the other.
//

import AppKit

/// A slider that says when it is being dragged, for the reason
/// `BrightnessSlider`'s does: `NSSlider.mouseDown` runs its own tracking loop,
/// so bracketing the call is enough to know.
private final class TrackingSlider: NSSlider {
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event)
        isTracking = false
    }
}

/// One display's speaker volume and mute, as a menu row.
@objc final class VolumeSliderItem: NSMenuItem {
    @objc let display: CGDirectDisplayID

    private let slider = TrackingSlider()
    private let readout = NSTextField(labelWithString: "")
    private let muteButton = NSButton()
    private let hasMute: Bool

    private var isMuted = false

    /// What the row is showing, which is where the volume keys step from.
    ///
    /// The row rather than the display, because asking the display costs a bus
    /// round trip and a key press cannot wait for one. It is the same value the
    /// user is looking at, and `reload()` brings it back in line whenever the
    /// menu opens.
    @objc private(set) var shownPercent = 0

    /// And whether it is showing the display as muted, for the same reason and
    /// with the same caveat: it is what the row last saw, not a fresh read.
    @objc var shownMuted: Bool { isMuted }

    /// A row for `display`, or nil when it has no volume control to offer.
    ///
    /// Nil rather than a disabled row, which is the call the brightness and HDR
    /// items already make: a menu is a list of things you can do, and most
    /// monitors have no speakers.
    @objc static func item(forDisplay display: CGDirectDisplayID) -> VolumeSliderItem? {
        guard EZDisplayAudio.supported(),
              EZDisplayAudio.available(forDisplay: display) else { return nil }
        let percent = EZDisplayAudio.percent(forDisplay: display)
        guard percent >= 0 else { return nil }
        return VolumeSliderItem(display: display, percent: percent)
    }

    private init(display: CGDirectDisplayID, percent: Int) {
        self.display = display
        // A display can implement one of the two codes and not the other, so
        // the button is only offered when the display answered a mute read.
        self.hasMute = EZDisplayAudio.muteAvailable(forDisplay: display)
        super.init(title: "Volume", action: nil, keyEquivalent: "")

        isMuted = hasMute && EZDisplayAudio.muted(forDisplay: display) == 1

        muteButton.setButtonType(.momentaryChange)
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.contentTintColor = .secondaryLabelColor
        muteButton.isEnabled = hasMute
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.widthAnchor.constraint(equalToConstant: 16).isActive = true

        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = Double(percent)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel("Volume")
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        readout.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                        weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.translatesAutoresizingMaskIntoConstraints = false
        readout.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let row = NSStackView(views: [muteButton, slider, readout])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        // The same insets the brightness row uses, so the two line up when a
        // display offers both.
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 12)
        row.frame.size = row.fittingSize

        show(percent)
        showMute()
        view = row
    }

    required init(coder: NSCoder) { fatalError("not used") }

    // Not copyable, for the reason BrightnessSliderItem is not: NSMenuItem's
    // copy would allocate one of these without running init, leaving `display`
    // and the subviews holding whatever was in the memory.
    override func copy(with zone: NSZone? = nil) -> Any {
        fatalError("VolumeSliderItem cannot be copied; build a new one instead")
    }

    /// Brings the row up to date from the display, unless the user is mid-drag.
    ///
    /// Nothing notifies when a monitor's own buttons move its volume, so this is
    /// called when the menu opens rather than on a change. Two DDC reads, so it
    /// is worth roughly a tenth of a second — call it once the menu is on
    /// screen, not while it is being built.
    @objc func reload() {
        guard !slider.isTracking else { return }
        readAndShow()
    }

    private func readAndShow() {
        let percent = EZDisplayAudio.percent(forDisplay: display)
        // A read that fails leaves the row where it is. The alternative is a
        // knob that drops to zero because the display was asleep.
        guard percent >= 0 else { return }
        slider.doubleValue = Double(percent)
        show(percent)

        if hasMute {
            let state = EZDisplayAudio.muted(forDisplay: display)
            if state >= 0 {
                isMuted = state == 1
                showMute()
            }
        }
    }

    @objc private func moved(_ sender: NSSlider) {
        write(Int(sender.doubleValue.rounded()))
    }

    /// Moves the row and the display to `percent`, for a caller that is not the
    /// knob: the volume keys.
    ///
    /// The knob moves too, which is the difference from a drag — during a drag
    /// the mouse is already holding it where it belongs.
    @objc func apply(_ percent: Int) {
        slider.doubleValue = Double(percent)
        write(percent)
    }

    /// Writes `percent`, and whatever that implies for mute.
    ///
    /// The two mute cases sit on opposite sides of the volume write and the
    /// order is load-bearing rather than tidy. Unmuting goes first, so the sound
    /// is on its way back before the louder value lands. Muting goes last,
    /// because a display unmutes itself on a volume write — set mute first and
    /// the zero that follows would lift it, leaving the row drawing a slash over
    /// a display that is not muted. Both are posted onto the one serial queue
    /// every DDC exchange uses, so posting order is bus order.
    private func write(_ percent: Int) {
        // Shown before the write, so the readout keeps up with the knob rather
        // than trailing a bus round trip behind it.
        show(percent)

        let action = EZVolumeMute.action(percent: percent,
                                         muted: isMuted,
                                         muteAtZero: EZPrefs.muteAtZero)
        if action == .unmute { setMute(false) }

        EZDisplayAudio.setPercentCoalesced(percent, forDisplay: display) { [weak self] applied in
            guard let self, !applied else { return }
            // A refused write puts the row back where the display actually is,
            // rather than leaving the slider and the readout standing at a
            // number nothing accepted — but not mid-drag, where it would pull
            // the knob out from under the mouse over one failed exchange.
            guard !self.slider.isTracking else { return }
            self.readAndShow()
        }

        if action == .mute { setMute(true) }
    }

    /// Moves mute alongside a volume write, at `EZVolumeMute`'s say-so.
    ///
    /// Shown before the write and posted rather than performed, both for the
    /// same reasons `write(_:)` does it with the percentage. The panel is drawn
    /// from `shownMuted` the moment the key handler returns, so a glyph that
    /// waited on the bus would draw the state the press was meant to leave
    /// behind; and this runs on a drag tick and on a key repeat, where a
    /// blocking write and its read-back would stop the knob under the mouse for
    /// a third of a second. A refused write is put right by the same
    /// `readAndShow()` a refused volume write is.
    ///
    /// Setting `isMuted` here is also what stops this repeating: every tick
    /// after the first one is asked about the state this left, so one gesture
    /// asks for one change however long it lasts, and a display that refuses is
    /// not asked again until something puts the row back.
    ///
    /// Not gated on `hasMute`. A display that never answered a mute read is
    /// never shown as muted, so the unmute case cannot arise; and the mute case
    /// is a write to a code that published a range, which is the rule that
    /// matters. `EZDisplayAudio` refuses the rest.
    private func setMute(_ muted: Bool) {
        isMuted = muted
        showMute()

        EZDisplayAudio.setMuted(muted, forDisplay: display) { [weak self] applied in
            guard let self, !applied else { return }
            guard !self.slider.isTracking else { return }
            self.readAndShow()
        }
    }

    /// Toggles mute from what the row is showing, not from a fresh read.
    ///
    /// A read here would cost an exchange to answer a question the row can
    /// already answer, and if it disagreed with what is on screen the button
    /// would do the opposite of what its icon just offered.
    ///
    /// The mute key lands here too. It blocks for the length of a write and its
    /// read-back, which is what the button already does, and a key that repeats
    /// is only acted on once.
    @objc func toggleMute() {
        let wanted = !isMuted
        if EZDisplayAudio.setMuted(wanted, forDisplay: display) {
            isMuted = wanted
            showMute()
        } else {
            readAndShow()
        }
    }

    private func show(_ percent: Int) {
        shownPercent = percent
        readout.stringValue = "\(percent)%"
        slider.setAccessibilityValueDescription("\(percent) percent")
    }

    private func showMute() {
        let symbol = isMuted ? "speaker.slash" : "speaker.wave.2"
        let label  = isMuted ? "Unmute" : "Mute"
        muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        muteButton.setAccessibilityLabel(hasMute ? label : "Volume")
        muteButton.toolTip = hasMute ? label : nil
    }
}
