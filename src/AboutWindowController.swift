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

        let summary = NSTextField(wrappingLabelWithString:
            "Resolution, brightness, volume, and color for every display, "
            + "from the menu bar.")
        summary.textColor = .secondaryLabelColor
        summary.alignment = .center
        summary.preferredMaxLayoutWidth = 340

        let copyright = NSTextField(wrappingLabelWithString:
            Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright")
                as? String ?? "")
        copyright.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyright.textColor = .tertiaryLabelColor
        copyright.alignment = .center
        copyright.preferredMaxLayoutWidth = 340

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 340
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
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

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
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        stack.setCustomSpacing(4, after: name)
        stack.setCustomSpacing(18, after: summary)
        stack.setCustomSpacing(18, after: buttonRow)

        // The separator has no width of its own inside a centering stack.
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                         constant: -56).isActive = true

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
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Checking…"
        offered = nil
        showInstallButton(false)
        resizeToFit()

        EZUpdater.check { [weak self] check in
            // Answers arrive long after the click, by which time the window may
            // have been closed and reopened, which is a fresh panel and not
            // this one.
            guard let self, generation == self.generation else { return }

            self.spinner.stopAnimation(nil)
            self.checkButton.isEnabled = true
            self.offered = check.updateAvailable ? check : nil
            self.showInstallButton(self.offered != nil)
            self.announce(check.status)
            self.resizeToFit()
        }
    }

    @objc private func installUpdate() {
        guard let release = offered, !installing else { return }

        installing = true
        checkButton.isEnabled = false
        installButton.isEnabled = false
        spinner.startAnimation(nil)
        announce("Downloading EZDisplay \(release.version ?? "").")
        resizeToFit()

        EZUpdater.installRelease(release) { [weak self] error in
            guard let self else { return }

            self.installing = false

            if let error {
                self.spinner.stopAnimation(nil)
                self.checkButton.isEnabled = true
                self.installButton.isEnabled = true
                self.announce(error)
                self.resizeToFit()
                return
            }

            // The buttons stay disabled: the bundle underneath this window has
            // already been replaced, so there is nothing left to do here but
            // start the copy that is now on disk.
            self.announce("EZDisplay \(release.version ?? "") is installed. Restarting…")
            self.resizeToFit()
            EZUpdater.relaunch()
        }
    }

    /// Writes a sentence into the status line and says it out loud.
    ///
    /// Spoken as well as shown because every one of these arrives long after
    /// the click that asked for it, by which time a screen reader has moved on
    /// and nothing else on the window has changed.
    private func announce(_ sentence: String) {
        statusLabel.stringValue = sentence
        NSAccessibility.post(element: statusLabel,
                             notification: .announcementRequested,
                             userInfo: [.announcement: sentence,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)

        // An install is replacing the bundle underneath this window and ends by
        // restarting the app. Resetting the panel would take away the sentence
        // saying so and put back the button that started it, and the restart
        // would then arrive out of nowhere.
        guard !installing else { return }

        // Cleared rather than left showing the last answer, which by the next
        // time the window opens may no longer be true. Bumping the generation
        // is what makes that stick: a check still running from last time now
        // has nowhere to write.
        generation += 1
        statusLabel.stringValue = ""
        offered = nil
        spinner.stopAnimation(nil)
        showInstallButton(false)
        installButton.isEnabled = true
        checkButton.isEnabled = true
        resizeToFit()
    }
}
