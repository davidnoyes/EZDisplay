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
    private let spinner = NSProgressIndicator()

    /// The release the last check found, when it found a newer one. Held so the
    /// download button knows what it is offering.
    private var offered: EZUpdateCheck?

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
        checkButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [spinner, checkButton])
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

    // MARK: - Checking

    @objc private func checkForUpdates() {
        checkButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Checking…"
        offered = nil

        EZUpdater.check { [weak self] check in
            guard let self else { return }

            self.spinner.stopAnimation(nil)
            self.checkButton.isEnabled = true
            self.statusLabel.stringValue = check.status
            self.offered = check.updateAvailable ? check : nil

            // Announced as well as shown, because the answer arrives long after
            // the click that asked for it and nothing else moves on screen.
            NSAccessibility.post(element: self.statusLabel,
                                 notification: .announcementRequested,
                                 userInfo: [.announcement: check.status,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Cleared rather than left showing the last answer, which by the next
        // time the window opens may no longer be true.
        statusLabel.stringValue = ""
        offered = nil
    }
}
