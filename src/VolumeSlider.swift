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
//  onto the bus during one drag, so the writes are coalesced and only the
//  readout keeps up with the knob.
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

    /// How long the knob has to stand still before the value goes to the
    /// display. Long enough that a drag across the track is a handful of writes
    /// rather than one per pixel, short enough that letting go feels immediate.
    private static let writeDelay: TimeInterval = 0.15

    private let slider = TrackingSlider()
    private let readout = NSTextField(labelWithString: "")
    private let muteButton = NSButton()
    private let hasMute: Bool

    private var isMuted = false
    private var pendingPercent = -1

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
        guard !slider.isTracking, pendingPercent < 0 else { return }
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
        let percent = Int(sender.doubleValue.rounded())
        // Shown before the write, so the readout keeps up with the knob rather
        // than trailing a bus round trip behind it.
        show(percent)
        pendingPercent = percent

        // Coalesce: every tick cancels the write the previous one scheduled, so
        // a drag lands one write per pause rather than one per pixel.
        //
        // The tracking mode matters. Without it the timer would not fire until
        // the drag ended, because NSSlider's tracking loop does not run the
        // default mode — and the volume would jump at the end of the drag
        // instead of following it.
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(writePending),
                                               object: nil)
        perform(#selector(writePending), with: nil,
                afterDelay: Self.writeDelay, inModes: [.default, .eventTracking])
    }

    @objc private func writePending() {
        let percent = pendingPercent
        guard percent >= 0 else { return }
        pendingPercent = -1

        // A refused write puts the row back where the display actually is,
        // rather than leaving the slider and the readout standing at a number
        // nothing accepted.
        if !EZDisplayAudio.setPercent(percent, forDisplay: display) {
            readAndShow()
        }
    }

    /// Toggles mute from what the row is showing, not from a fresh read.
    ///
    /// A read here would cost an exchange to answer a question the row can
    /// already answer, and if it disagreed with what is on screen the button
    /// would do the opposite of what its icon just offered.
    @objc private func toggleMute() {
        let wanted = !isMuted
        if EZDisplayAudio.setMuted(wanted, forDisplay: display) {
            isMuted = wanted
            showMute()
        } else {
            readAndShow()
        }
    }

    private func show(_ percent: Int) {
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
