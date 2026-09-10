//
//  VolumeHUD.swift
//  EZDisplay
//
//  The panel that says a volume key did something, and the click that goes
//  with it.
//
//  Not decoration. macOS draws no feedback for a key an event tap swallowed,
//  and a monitor's own volume moving is silent and invisible, so without this
//  the working feature and a broken one produce identical evidence: nothing
//  happens. That is not a theory — the volume keys were reported as dead twice
//  while they were working the whole time.
//
//  Apple's own panel is out of reach, and both halves of that are worth
//  recording because the obvious route looks like it works. `OSDUIHelper`, the
//  mach service every other project drives, can only draw the pre-Tahoe bezel:
//  a dark square at the bottom of the screen, in a style macOS 26 uses nowhere
//  else. Its whole vocabulary is five `showImage` variants over `OSDRoundWindow`
//  and `fadeClassicImageOnDisplay:`, so there is no newer entry point hiding in
//  it. What macOS 26 actually draws is a system banner belonging to
//  ControlCenter, behind `com.apple.private.system-banner-client` — an
//  Apple-only entitlement, and one whose check happens per message rather than
//  at connect time, so an unentitled connection succeeds and tells you nothing.
//
//  So this is drawn here, and the cost of that is honest: these are our own
//  pixels, they can drift from Apple's when macOS changes, and nothing will say
//  so. The alternative was a genuinely system-drawn panel that already looks
//  wrong.
//

import AppKit

/// What a raw `com.apple.sound.beep.feedback` value means.
///
/// Separate from the read so it can be tested, because the absent case is the
/// common one and it is the one with a wrong answer available: macOS writes the
/// key only once the box has been changed, so on most machines there is nothing
/// there and the click has to survive that.
func volumeFeedbackEnabled(_ raw: Any?) -> Bool {
    guard let raw else { return true }
    return (raw as? NSNumber)?.boolValue ?? true
}

/// The sentence VoiceOver is given for a level the panel only draws.
///
/// Separate from the posting so it can be tested, and worth testing because the
/// panel carries no text: nothing on screen would contradict a wrong sentence,
/// and the thing it replaces was VoiceOver reading the panel's role out loud.
func volumeAnnouncement(percent: Int, muted: Bool) -> String {
    if muted { return "Muted" }
    return "Volume \(min(max(percent, 0), 100))%"
}

/// The bar, as sixteen rounded segments.
///
/// Segments rather than a continuous fill because the keys move in sixteen
/// steps: a press that moved a smooth bar by a sliver would be easy to miss,
/// and one whole segment is not.
private final class ChicletBar: NSView {
    var lit = 0 { didSet { needsDisplay = true } }
    var total = 16 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard total > 0 else { return }

        let gap: CGFloat = 3
        let width = (bounds.width - gap * CGFloat(total - 1)) / CGFloat(total)
        let radius: CGFloat = 2.5

        for index in 0 ..< total {
            let box = NSRect(x: CGFloat(index) * (width + gap), y: 0,
                             width: width, height: bounds.height)
            (index < lit ? NSColor.labelColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// The feedback panel, and the sound that goes with it.
///
/// One panel for the whole app, reused: it is shown several times a second by a
/// held key, and building a window for each press would be visible.
@objc final class VolumeHUD: NSObject {
    // Internal rather than private, and only so a test can reach the panel.
    // What the panel says about itself to the accessibility tree is the whole
    // of the fix for VoiceOver reading it out as "system dialog", and two
    // setter calls in an initializer are deleted by accident far more easily
    // than they are noticed missing — the symptom is a screen reader saying
    // the wrong thing, which nobody sighted will ever see.
    static let shared = VolumeHUD()

    /// The click macOS plays for its own volume keys, taken from where macOS
    /// keeps it rather than shipped again here.
    private static let soundPath =
        "/System/Library/LoginPlugins/BezelServices.loginPlugin"
        + "/Contents/Resources/volume.aiff"

    /// How long the panel stays up before it starts to go, matching the
    /// `msecUntilFade` Apple's own bezel is asked for.
    private static let linger: TimeInterval = 1.0
    private static let fade: TimeInterval = 0.25

    let panel: NSPanel
    private let glyph = NSImageView()
    private let bar = ChicletBar()
    private var dismissal: DispatchWorkItem?
    private lazy var sound = NSSound(contentsOfFile: VolumeHUD.soundPath, byReference: true)

    private override init() {
        let size = NSSize(width: 200, height: 44)

        // Non-activating, because a volume key must not take focus off whatever
        // the user is typing into, and borderless because the panel is the
        // rounded rectangle rather than something inside a frame.
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        // Above ordinary windows and the menu bar, which is where feedback for
        // a key that works everywhere has to sit.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                                    .ignoresCycle]

        // Out of the accessibility tree entirely, which is a fix rather than a
        // hiding. A titleless borderless panel at this level is given the
        // subrole `AXSystemDialog`, and VoiceOver reads a system dialog out as
        // it appears — so every volume key said "system dialog", announcing
        // that something had happened without saying what. There is no title to
        // give it either: the panel is a glyph and a bar, and it must not take
        // focus. `announce(percent:muted:)` says the level instead.
        panel.setAccessibilityElement(false)
        panel.setAccessibilityRole(.unknown)

        glyph.frame = NSRect(x: 14, y: 12, width: 20, height: 20)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .labelColor

        bar.frame = NSRect(x: 44, y: 18, width: size.width - 44 - 14, height: 8)

        panel.contentView = VolumeHUD.backdrop(size: size, holding: [glyph, bar])

        super.init()
    }

    /// The rounded rectangle everything else sits on.
    ///
    /// Glass on macOS 26, because that is what the panel this stands in for is
    /// made of, and a blur next to it reads as the previous version of the OS.
    /// The two are not interchangeable: `NSGlassEffectView` refracts and tints
    /// what is behind it rather than only blurring it, and it takes its content
    /// as a subview it owns instead of being a superview to add to.
    ///
    /// The fallback is the panel as it was, and it is not only a formality —
    /// the deployment target is macOS 11. Its `.hudWindow` material is dark in
    /// both appearances, which is what a HUD was before macOS 26; the glass
    /// follows the system appearance instead, which is what settles the
    /// light-mode question the blur could not.
    private static func backdrop(size: NSSize, holding subviews: [NSView]) -> NSView {
        if #available(macOS 26, *) {
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            subviews.forEach { content.addSubview($0) }

            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.cornerRadius = 16
            glass.contentView = content
            return glass
        }

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        subviews.forEach { blur.addSubview($0) }
        return blur
    }

    /// Shows the panel for a display at `lit` of `total` chiclets.
    ///
    /// Call it on the main thread, once per press that moved something. A
    /// second call while the panel is up puts the timer back to the start
    /// rather than letting a held key fade out from under itself.
    @objc static func show(lit: Int, of total: Int, muted: Bool) {
        // Asserted rather than left to the comment, because the first call is
        // the one that builds the panel, and building an NSWindow off the main
        // thread misbehaves later rather than here.
        dispatchPrecondition(condition: .onQueue(.main))
        shared.show(lit: lit, total: total, muted: muted)
    }

    private func show(lit: Int, total: Int, muted: Bool) {
        let symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        bar.total = total
        bar.lit = lit

        place()

        dismissal?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let dismiss = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissal = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + VolumeHUD.linger, execute: dismiss)
    }

    /// Top right, which is where macOS 26 puts its own.
    ///
    /// Which display that is, with two of them, is not settled. `NSScreen.main`
    /// is documented as the screen holding the window with keyboard focus, and
    /// this app is `LSUIElement` with no window of its own, so what it returns
    /// here is the frontmost application's — or, with nothing focused, the
    /// screen the menu bar is on. That is a reasonable answer and it may well
    /// be the right one, but it has not been tested against two monitors,
    /// because there is only one here. Do not read the fallback as a second
    /// opinion: `screens.first` is the menu-bar screen again.
    private func place() {
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let margin: CGFloat = 12
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - margin,
                                     y: frame.maxY - size.height - margin))
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = VolumeHUD.fade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Only if nothing showed it again while the fade was running,
            // which a key pressed at the wrong moment will do.
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        })
    }

    /// System Settings › Sound › **Play feedback when volume is changed**.
    ///
    /// Read through `UserDefaults`, not by parsing `.GlobalPreferences.plist`
    /// off disk the way MonitorControl does: the file lags a change until
    /// `cfprefsd` flushes it, and the defaults read does not.
    @objc static var feedbackSoundEnabled: Bool {
        volumeFeedbackEnabled(UserDefaults.standard.object(forKey: "com.apple.sound.beep.feedback"))
    }

    /// Says the level out loud, for the panel VoiceOver can no longer see.
    ///
    /// Posted against the application rather than the panel, because the panel
    /// was deliberately taken out of the accessibility tree and an element that
    /// is not in the tree is not one to speak from.
    ///
    /// Not gated on the Sound pane's feedback setting, and not gated on
    /// VoiceOver running either. The first is a decision — someone who switched
    /// the click off switched off a sound, not their screen reader. The second
    /// is unnecessary: with nothing listening the post does nothing.
    @objc static func announce(percent: Int, muted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: volumeAnnouncement(percent: percent, muted: muted),
                       .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Plays the click, restarting it if the last one has not finished.
    @objc static func playFeedbackSound() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let sound = shared.sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
