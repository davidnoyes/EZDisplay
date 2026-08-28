//
//  SafeApply.swift
//  EZDisplay
//
//  Confirm-or-revert safety net for live display changes. A change is applied,
//  then a floating panel counts down from 20s and auto-reverts to the previous
//  working state unless the user confirms (Revert = Return/Space/Escape/button;
//  Keep = mouse only; timeout = revert). Reused by resolution, mirroring, and
//  HDR so a change that blacks out the screen can always be undone.
//
//  Every keyboard route leads to Revert, deliberately. This panel exists for
//  the case where the screen is unreadable, and a user who cannot see it will
//  still reach for Return. That reflex has to land on the safe outcome, so
//  keeping a change costs a deliberate click on a button you can see.
//

import Cocoa

/// Escape has to keep working now that Return belongs to Revert: an NSButton
/// carries only one key equivalent, and Return took the one Escape used to use.
private final class SafeApplyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@objc class SafeApply: NSObject {

    private static let shared = SafeApply()
    private static let applyQueue = DispatchQueue(label: "io.github.davidnoyes.ezdisplay.safeapply")
    private let totalSeconds = 20

    private var panel: NSPanel?
    private var timer: Timer?
    private var secondsLeft = 20
    private var pendingReverts: [() -> Void] = []
    private var pendingDetails: [String] = []

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let countdownBar = NSProgressIndicator()
    private let countdownLabel = NSTextField(labelWithString: "")
    private let vstack = NSStackView()
    private let buttonRow = NSStackView()

    // Alert proportions: a 64pt icon in a column of its own, the text beside it,
    // buttons under both. Matching NSAlert's geometry is most of what makes a
    // hand-built panel stop looking hand-built.
    private let panelWidth: CGFloat = 460
    private let panelInset: CGFloat = 20
    private let iconSize: CGFloat = 64
    private let iconGap: CGFloat = 16
    private var textWidth: CGFloat { panelWidth - 2 * panelInset - iconSize - iconGap }

    // MARK: - Public API

    /// A change has already been applied; require confirmation or auto-revert.
    /// `revert` restores the previous state (run on revert/timeout/Escape).
    @objc static func confirm(title: String, detail: String, revert: @escaping () -> Void) {
        onMain { shared.begin(title: title, detail: detail, revert: revert) }
    }

    /// Capture the display's current mode, apply `modeNum`, then confirm-or-revert.
    @objc static func setDisplayMode(_ display: CGDirectDisplayID, modeNum: Int32, detail: String) {
        let old = EZDisplays.currentModeNum(forDisplay: display)
        applyQueue.async {
            _ = EZDisplays.setModeNum(modeNum, forDisplay: display)
            onMain {
                confirm(title: "Keep this display setting?", detail: detail) {
                    applyQueue.async { _ = EZDisplays.setModeNum(old, forDisplay: display) }
                }
            }
        }
    }

    /// Run a write to the display hardware off the main thread, on the one queue
    /// every such write shares.
    ///
    /// Both halves matter. Off the main thread, because restarting a display
    /// link does not return until the picture has gone and come back, and doing
    /// that inline freezes the countdown panel exactly while the screen is
    /// unreadable and the panel is the only way out. On a shared serial queue,
    /// because a resolution change and a colour-mode change landing on the same
    /// hardware at the same instant is not a case anyone has reasoned about.
    @objc static func onApplyQueue(_ block: @escaping () -> Void) {
        applyQueue.async(execute: block)
    }

    private static func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - Session

    private func begin(title: String, detail: String, revert: @escaping () -> Void) {
        // Chaining: keep every pending revert, so successive changes still undo
        // all the way back to the original good state. Keeping only the first
        // was enough while every caller changed the same thing — two resolution
        // changes on one display — but HDR, resolution, and mirroring are
        // independent, so a dropped revert leaves that change applied while the
        // panel says it reverted. Reset the countdown and relabel as before.
        pendingReverts.append(revert)
        if !detail.isEmpty { pendingDetails.append(detail) }

        secondsLeft = totalSeconds
        if panel == nil { buildPanel() }
        // One panel serves the whole chain, so a second change used to retitle it
        // to name only the newest one. That reads as the first panel being
        // dismissed by something other than the user, and hides that the earlier
        // change is still waiting on the same answer. Say so instead.
        titleLabel.stringValue = pendingReverts.count > 1 ? "Keep these display changes?" : title
        // List every change still pending, not just the newest. Overwriting this
        // line dropped the earlier change's text along with any warning in it —
        // the HDR detail says the picture settles by itself, which is exactly what
        // the user needs when a resolution change lands on top of a half-settled
        // HDR switch.
        // Bulleted once there is more than one, because a detail can wrap and two
        // wrapped sentences run together into a single block otherwise.
        detailLabel.attributedStringValue = bulletedDetail()
        detailLabel.isHidden = pendingDetails.isEmpty
        countdownBar.maxValue = Double(totalSeconds)
        updateCountdown()

        NSApp.activate(ignoringOtherApps: true)
        if let panel = panel {
            resizePanelToFit(panel)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            // Focus Revert, so Space lands on the safe action too.
            if let revert = panel.contentView?.viewWithTag(1) { panel.makeFirstResponder(revert) }
        }

        timer?.invalidate()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        secondsLeft -= 1
        if secondsLeft <= 0 { finish(revert: true) } else { updateCountdown() }
    }

    /// One bullet per pending change, with a hanging indent so a wrapped line
    /// starts under its own text rather than back at the bullet — the single
    /// detail that most made the plain-string version look unfinished. A lone
    /// change gets no bullet, because a one-item list is not a list.
    private func bulletedDetail() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        guard pendingDetails.count > 1 else {
            return NSAttributedString(string: pendingDetails.joined(), attributes: attrs)
        }
        let style = NSMutableParagraphStyle()
        // The tab stop and the head indent have to be the same number, or the
        // hanging indent is not hanging: tabStops defaults to 28pt, so the
        // first line's text would start there while wrapped lines started at
        // headIndent, 14pt to its left — between the bullet and the text.
        style.headIndent = 14
        style.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        style.paragraphSpacing = 4
        var indented = attrs
        indented[.paragraphStyle] = style
        return NSAttributedString(string: pendingDetails.map { "•\t\($0)" }.joined(separator: "\n"),
                                  attributes: indented)
    }

    private func updateCountdown() {
        let unit = secondsLeft == 1 ? "second" : "seconds"
        // The detail lines above already enumerate the pending changes, so this
        // says "all changes" rather than counting them again — "all 2 changes"
        // is not how anyone writes it.
        let what = pendingReverts.count > 1 ? "all changes" : "the previous setting"
        countdownLabel.stringValue = "Reverting \(what) in \(secondsLeft) \(unit)…"
        countdownBar.doubleValue = Double(secondsLeft)
    }

    @objc private func keepAction() { finish(revert: false) }
    @objc private func revertAction() { finish(revert: true) }

    private func finish(revert: Bool) {
        timer?.invalidate(); timer = nil
        let reverts = pendingReverts
        pendingReverts = []
        pendingDetails = []
        panel?.orderOut(nil)
        // Newest first, so each change is undone against the state it was made
        // against and the display ends where it started.
        if revert { runReverts(Array(reverts.reversed())) }
    }

    /// Reverts run one at a time with a gap, never as a burst. A mode change
    /// resets the link and takes HDR down with it, and `setDisplayMode` reverts
    /// asynchronously, so firing them back to back lets a later revert land
    /// mid-change and be silently undone — measured: the resolution came back
    /// and HDR stayed off.
    private func runReverts(_ pending: [() -> Void]) {
        guard let next = pending.first else { return }
        next()
        let rest = Array(pending.dropFirst())
        guard !rest.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.runReverts(rest) }
    }

    // MARK: - Panel

    /// The detail area lists one line per pending change and wraps long ones, so
    /// the panel is only as tall as its content. Sized by hand rather than by a
    /// constraint on the content view, because AppKit owns a window's content
    /// view frame and a width constraint there fights it.
    private func resizePanelToFit(_ panel: NSPanel) {
        // The icon column sets a floor: a one-line change must not produce a
        // panel shorter than its own icon.
        let bodyHeight = max(iconSize, vstack.fittingSize.height)
        let height = panelInset + bodyHeight + 18 + buttonRow.fittingSize.height + panelInset
        // Never taller than the screen. Enough chained changes, or one long
        // enough detail, would otherwise grow the panel past the display and
        // carry Revert Now off the bottom — the one button that must stay
        // reachable. The button row is pinned to the content's bottom edge, so
        // clamping squeezes the text and never the controls.
        let ceiling = (NSScreen.main?.visibleFrame.height ?? 800) - 40
        panel.setContentSize(NSSize(width: panelWidth, height: min(ceil(height), ceiling)))
    }

    private func buildPanel() {
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // The headline carries the question, so it is a step up from body text
        // rather than merely bold at the same size.
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.preferredMaxLayoutWidth = textWidth

        detailLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.preferredMaxLayoutWidth = textWidth

        // Draining rather than filling: the bar is time left, and it reaches
        // empty exactly when the revert fires. Time is the whole point of this
        // panel and a number alone does not convey it at a glance.
        countdownBar.isIndeterminate = false
        countdownBar.style = .bar
        countdownBar.minValue = 0
        countdownBar.maxValue = Double(totalSeconds)
        countdownBar.translatesAutoresizingMaskIntoConstraints = false
        countdownBar.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        countdownLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        countdownLabel.textColor = .secondaryLabelColor

        let keep = NSButton(title: "Keep", target: self, action: #selector(keepAction))
        keep.bezelStyle = .rounded
        // No key equivalent: keeping a change is the outcome that cannot be
        // undone by waiting, so it takes a click rather than a reflex.
        let revert = NSButton(title: "Revert Now", target: self, action: #selector(revertAction))
        revert.bezelStyle = .rounded
        revert.keyEquivalent = "\r"    // default button; Return and Space revert
        revert.tag = 1

        vstack.setViews([titleLabel, detailLabel, countdownBar, countdownLabel], in: .leading)
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 8
        // The bar belongs with the sentence that explains it, not floating
        // equidistant between the detail above and the label below.
        vstack.setCustomSpacing(6, after: countdownBar)
        vstack.translatesAutoresizingMaskIntoConstraints = false

        // Revert last, so the default button sits where macOS puts one: at the
        // trailing edge, under the hand of anyone who clicks the rightmost
        // button without reading. That reflex lands on the safe outcome too.
        buttonRow.setViews([keep, revert], in: .leading)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 150))
        content.addSubview(iconView)
        content.addSubview(vstack)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: panelInset),
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: panelInset),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            vstack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: iconGap),
            vstack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -panelInset),
            vstack.topAnchor.constraint(equalTo: content.topAnchor, constant: panelInset),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: vstack.bottomAnchor, constant: 18),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor, constant: 18),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -panelInset),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -panelInset),
        ])

        // No title bar. An alert does not have one, and an empty grey strip
        // above the icon was most of what made this read as a stray window
        // rather than a prompt. The panel stays draggable by its background,
        // and Escape still reverts, so nothing is lost with the close button.
        let p = SafeApplyPanel(contentRect: content.frame,
                               styleMask: [.titled, .fullSizeContentView],
                               backing: .buffered, defer: false)
        p.onCancel = { [weak self] in self?.finish(revert: true) }
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        // Hidden from the title bar, but still the panel's accessible name:
        // titleVisibility only silences the drawn text, and VoiceOver has
        // nothing else to announce this window by.
        p.title = "EZDisplay"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = content
        panel = p
    }
}
