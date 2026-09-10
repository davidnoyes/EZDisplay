//
//  AboutWindowController.swift
//  EZDisplay
//
//  The About window, replacing AppKit's standard one.
//
//  The standard panel shows the version and nothing else, and the version is
//  not the question anyone opens About to ask — "am I on the latest?" is. That
//  needs a button, a line of status, and somewhere to put them, none of which
//  the standard panel has room for. What the status says is decided in
//  Update.mm, where a test can read it; this file is the window it goes in.
//

import Cocoa

class AboutWindowController: NSWindowController {

    /// How wide the text is allowed to get, and how much room is left either
    /// side of it.
    ///
    /// Nothing else decides the width of this window: it is sized to fit, and
    /// the widest thing in it is a wrapped paragraph held to the column. So the
    /// margin is not a nicety here, it is the only thing keeping the sentences
    /// off the edges of the frame.
    private static let column: CGFloat = 320
    private static let margin: CGFloat = 44

    private let statusLabel = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: "Check for Updates",
                                       target: nil, action: nil)
    private let installButton = NSButton(title: "Install Update",
                                         target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    /// The release the last check found, when it found a newer one. Held so the
    /// download button knows what it is offering.
    private var offered: EZUpdateCheck?

    /// Bumped every time the window is opened afresh. One controller is kept
    /// for the life of the app, so a check still in flight from the last time
    /// the window was open would otherwise write its answer — and re-offer its
    /// release — over a panel that has since been reset.
    private var generation = 0

    /// True from the click on **Install Update** until the swap has finished.
    ///
    /// An install cannot be abandoned halfway: the bundle underneath is being
    /// replaced, and the last thing it does is restart the app. So a window
    /// reopened while one is running is left exactly as it is, rather than
    /// clearing the sentence that says so and re-enabling the buttons that
    /// would start a second one.
    private var installing = false

    @objc convenience init() {
        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        // Titled rather than a bare panel: VoiceOver reads an untitled panel as
        // a system dialog, and this is a window about an app.
        window.title = "About EZDisplay"
        window.isReleasedWhenClosed = false
        self.init(window: window)

        window.contentView = buildContent()
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
    }

    // MARK: - Building it

    private func buildContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        // Decoration beside the name it duplicates, so a screen reader that
        // reads both says the app's name twice.
        icon.setAccessibilityElement(false)

        let name = NSTextField(labelWithString: "EZDisplay")
        name.font = .systemFont(ofSize: 22, weight: .semibold)

        let version = NSTextField(labelWithString:
            "Version \(EZUpdater.currentVersion()) (build \(EZUpdater.currentBuild()))")
        version.textColor = .secondaryLabelColor

        // Names refresh rate and HDR, which the app is largely for and the
        // previous wording left out. Not a list of everything it does — there
        // is no room for mirroring, Night Shift, and custom resolutions as
        // well — so it reads as the headline features rather than the manifest.
        let summary = NSTextField(wrappingLabelWithString:
            "Resolution, refresh rate, HDR, color, brightness, and volume "
            + "for every display — from the menu bar.")
        summary.textColor = .secondaryLabelColor
        holdToColumn(summary)

        let copyright = NSTextField(wrappingLabelWithString:
            Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright")
                as? String ?? "")
        copyright.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyright.textColor = .tertiaryLabelColor
        holdToColumn(copyright)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        holdToColumn(statusLabel)
        // Two lines' worth of room whether or not there is anything to say, so
        // the ordinary answers appear without the window changing size under
        // the pointer. Only a long failure message needs more, and resizeToFit
        // gives it more.
        let lineHeight = statusLabel.font?.boundingRectForFont.height ?? 16
        statusLabel.heightAnchor.constraint(
            greaterThanOrEqualToConstant: ceil(lineHeight * 2)).isActive = true
        // The check writes here, so a reader that is not looking at the window
        // when the answer arrives is still told.
        statusLabel.setAccessibilityRole(.staticText)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        setBusy(false)

        checkButton.target = self
        checkButton.action = #selector(checkForUpdates)
        checkButton.bezelStyle = .rounded

        installButton.target = self
        installButton.action = #selector(installUpdate)
        installButton.bezelStyle = .rounded

        showInstallButton(false)

        let buttonRow = NSStackView(views: [spinner, checkButton, installButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [icon, name, version, summary,
                                        separator, statusLabel, buttonRow,
                                        copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: Self.margin,
                                        bottom: 20, right: Self.margin)
        stack.setCustomSpacing(4, after: name)
        stack.setCustomSpacing(18, after: summary)
        stack.setCustomSpacing(18, after: buttonRow)

        // Pinned as well as inset, because `edgeInsets` is not a required
        // constraint across a vertical stack: fitting the window to its content
        // ignores the left and right of it, and the window comes out exactly as
        // wide as the text with no margin at all.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(
            equalToConstant: Self.column + 2 * Self.margin).isActive = true

        // The separator has no width of its own inside a centering stack.
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(
            equalToConstant: Self.column).isActive = true

        return stack
    }

    /// Fits the window to its content, keeping the title bar where it is.
    ///
    /// The status is the one thing in here whose height is not known when the
    /// window is built, so the size has to follow it. Without this a long
    /// failure message has nowhere to go and is simply not shown.
    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        let fitting = content.fittingSize
        guard fitting != content.frame.size else { return }

        // A window grows from its bottom-left corner, which would walk the
        // title bar up the screen each time the status got taller.
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(fitting)
        window.setFrameTopLeftPoint(topLeft)
    }

    /// Wraps a label to the text column, centered.
    ///
    /// The three of these have to agree, because the widest of them is what
    /// the window is sized around and the margin is what is left over.
    private func holdToColumn(_ label: NSTextField) {
        label.alignment = .center
        label.preferredMaxLayoutWidth = Self.column
    }

    /// Starts or stops the spinner, and takes its space back when it stops.
    ///
    /// Hidden rather than left to `isDisplayedWhenStopped`, which stops it
    /// drawing but keeps its width. Sixteen invisible points and their spacing
    /// beside one centered button are enough to make the button look as though
    /// it is not centered, because it is not.
    ///
    /// Not private, so a test can put the panel into its busy state. There is
    /// no other way in: the states that set this are reached only by a real
    /// check against GitHub.
    func setBusy(_ busy: Bool) {
        spinner.isHidden = !busy

        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    /// Shows or hides the install button, and gives the Return key to whichever
    /// button now matters.
    ///
    /// Hidden until a check finds something, so the panel never offers an
    /// update it does not have. NSStackView reclaims the space.
    private func showInstallButton(_ shown: Bool) {
        installButton.isHidden = !shown
        checkButton.keyEquivalent = shown ? "" : "\r"
        installButton.keyEquivalent = shown ? "\r" : ""
    }

    // MARK: - Checking

    @objc private func checkForUpdates() {
        let generation = self.generation

        checkButton.isEnabled = false
        setBusy(true)
        statusLabel.stringValue = "Checking…"
        offered = nil
        showInstallButton(false)
        resizeToFit()

        EZUpdater.check { [weak self] check in
            // Answers arrive long after the click, by which time the window may
            // have been closed and reopened, which is a fresh panel and not
            // this one.
            guard let self, generation == self.generation else { return }

            self.setBusy(false)
            self.checkButton.isEnabled = true
            self.offered = check.updateAvailable ? check : nil
            self.showInstallButton(self.offered != nil)
            self.announce(check.status)
        }
    }

    @objc private func installUpdate() {
        guard let release = offered, !installing else { return }

        installing = true
        checkButton.isEnabled = false
        installButton.isEnabled = false
        setBusy(true)
        announce("Downloading EZDisplay \(release.version ?? "").")

        EZUpdater.installRelease(release) { [weak self] error in
            guard let self else { return }

            self.installing = false

            if let error {
                self.setBusy(false)
                self.checkButton.isEnabled = true
                self.installButton.isEnabled = true
                self.announce(error)
                return
            }

            // The buttons stay disabled: the bundle underneath this window has
            // already been replaced, so there is nothing left to do here but
            // start the copy that is now on disk.
            self.announce("EZDisplay \(release.version ?? "") is installed. Restarting…")
            EZUpdater.relaunch()
        }
    }

    /// Writes a sentence into the status line, says it out loud, and makes
    /// room for it.
    ///
    /// Spoken as well as shown because every one of these arrives long after
    /// the click that asked for it, by which time a screen reader has moved on
    /// and nothing else on the window has changed.
    ///
    /// Resizing is part of the same act rather than a call beside it, because
    /// it was one at all four call sites and the one that got forgotten would
    /// be the long failure message that needed it. Not private, so a test can
    /// put a long sentence in and measure what the window does with it.
    func announce(_ sentence: String) {
        statusLabel.stringValue = sentence
        NSAccessibility.post(element: statusLabel,
                             notification: .announcementRequested,
                             userInfo: [.announcement: sentence,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        resizeToFit()
    }

    override func showWindow(_ sender: Any?) {
        // Selecting About while the window is already open just brings it
        // forward, so there is nothing to reset. Read before the call, because
        // the call is what makes it visible.
        let reopened = !(window?.isVisible ?? false)

        super.showWindow(sender)

        // An install is replacing the bundle underneath this window and ends by
        // restarting the app. Resetting the panel would take away the sentence
        // saying so and put back the button that started it, and the restart
        // would then arrive out of nowhere.
        guard reopened, !installing else { return }

        // Cleared rather than left showing the last answer, which by the next
        // time the window opens may no longer be true. Bumping the generation
        // is what makes that stick: a check still running from last time now
        // has nowhere to write.
        generation += 1
        statusLabel.stringValue = ""
        offered = nil
        setBusy(false)
        showInstallButton(false)
        installButton.isEnabled = true
        checkButton.isEnabled = true
        resizeToFit()
    }
}
