//
//  CustomResolutionsWindowController.swift
//  EZDisplay
//
//  A small, intent-focused editor for a display's custom scaled resolutions:
//  list them, add one with Width / Height / HiDPI and an optional lock-to-ratio
//  helper, remove, and save. Replaces the old storyboard "Edit" dialog.
//

import Cocoa

@objc class CustomResolutionsWindowController: NSWindowController {
    // displayAspectRatio (width/height) seeds the lock-to-ratio helper; pass 0 if unknown.
    @objc convenience init(vendorID: UInt32, productID: UInt32, displayName: String, displayAspectRatio: Double) {
        let vc = CustomResolutionsViewController(
            store: CustomResolutionsStore(vendorID: vendorID, productID: productID, displayName: displayName),
            displayAspectRatio: displayAspectRatio)
        let window = NSWindow(contentViewController: vc)
        window.title = displayName.isEmpty ? "Custom Resolutions" : "Custom Resolutions — \(displayName)"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 460))
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

class CustomResolutionsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private let store: CustomResolutionsStore
    private let displayAspectRatio: Double
    private var resolutions: [Resolution] = []
    private var lockRatio: Double = 16.0 / 9.0

    private let tableView = NSTableView()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let hidpiCheck = NSButton(checkboxWithTitle: "HiDPI (renders sharp / pixel-doubled)", target: nil, action: nil)
    private let lockCheck = NSButton(checkboxWithTitle: "Lock aspect ratio", target: nil, action: nil)
    private let previewLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    init(store: CustomResolutionsStore, displayAspectRatio: Double) {
        self.store = store
        self.displayAspectRatio = displayAspectRatio
        if displayAspectRatio > 0 { lockRatio = displayAspectRatio }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 460))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        resolutions = store.load().sorted { $0.width > $1.width || ($0.width == $1.width && $0.height > $1.height) }
        buildUI()
        updatePreview()
    }

    // MARK: UI

    private func buildUI() {
        // Existing custom resolutions
        let listLabel = NSTextField(labelWithString: "Custom resolutions for this display")
        let wCol = NSTableColumn(identifier: .init("w"));  wCol.title = "Width";     wCol.width = 90
        let hCol = NSTableColumn(identifier: .init("h"));  hCol.title = "Height";    hCol.width = 90
        let dCol = NSTableColumn(identifier: .init("d"));  dCol.title = "HiDPI";     dCol.width = 60
        let pCol = NSTableColumn(identifier: .init("p"));  pCol.title = "Renders at"; pCol.width = 140
        [wCol, hCol, dCol, pCol].forEach { tableView.addTableColumn($0) }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded

        // Add form
        let addLabel = NSTextField(labelWithString: "Add a resolution")
        addLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        widthField.placeholderString = "Width"
        heightField.placeholderString = "Height"
        for f in [widthField, heightField] {
            f.delegate = self
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        let times = NSTextField(labelWithString: "×")
        let addButton = NSButton(title: "Add", target: self, action: #selector(addResolution))
        addButton.keyEquivalent = "\r"
        let dimRow = NSStackView(views: [widthField, times, heightField, addButton])
        dimRow.orientation = .horizontal
        dimRow.spacing = 8

        hidpiCheck.state = .on
        hidpiCheck.target = self; hidpiCheck.action = #selector(fieldsChanged)
        lockCheck.target = self;  lockCheck.action = #selector(lockToggled)
        previewLabel.textColor = .secondaryLabelColor

        let note = NSTextField(labelWithString: "Custom resolutions apply after you log out or restart.")
        note.textColor = .tertiaryLabelColor
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        // Bottom buttons
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        let bottom = NSStackView(views: [note, NSView(), cancel, save])
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let stack = NSStackView(views: [
            listLabel, scroll, removeButton,
            NSBox.hSeparator(),
            addLabel, dimRow, hidpiCheck, lockCheck, previewLabel,
            NSBox.hSeparator(),
            bottom,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bottom.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { resolutions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = resolutions[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "w": text = "\(r.width)"
        case "h": text = "\(r.height)"
        case "d": text = r.HiDPI ? "✓" : "—"
        case "p": text = r.HiDPI ? "\(r.width * 2) × \(r.height * 2)" : "\(r.width) × \(r.height)"
        default:  text = ""
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
        return cell
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        if lockCheck.state == .on, (obj.object as? NSTextField) === widthField {
            let w = widthField.integerValue
            if w > 0 && lockRatio > 0 {
                heightField.integerValue = Int((Double(w) / lockRatio).rounded())
            }
        }
        updatePreview()
    }

    @objc private func fieldsChanged() { updatePreview() }

    @objc private func lockToggled() {
        // Seed the locked ratio from the current fields if valid, else the display's.
        let w = widthField.integerValue, h = heightField.integerValue
        if w > 0 && h > 0 { lockRatio = Double(w) / Double(h) }
        else if displayAspectRatio > 0 { lockRatio = displayAspectRatio }
        if lockCheck.state == .on, w > 0 {
            heightField.integerValue = Int((Double(w) / lockRatio).rounded())
        }
        updatePreview()
    }

    private func updatePreview() {
        let w = widthField.integerValue, h = heightField.integerValue
        guard w > 0 && h > 0 else {
            previewLabel.stringValue = "Enter a width and height."
            return
        }
        let hidpi = hidpiCheck.state == .on
        let px = hidpi ? "\(w * 2) × \(h * 2)" : "\(w) × \(h)"
        previewLabel.stringValue = "Adds \(w) × \(h)\(hidpi ? " HiDPI" : "") — rendered at \(px)"
    }

    @objc private func addResolution() {
        let w = widthField.integerValue, h = heightField.integerValue
        guard w > 0 && h > 0 else { NSSound.beep(); return }

        let res = Resolution()
        res.HiDPI = (hidpiCheck.state == .on)   // set flag before dimensions (setter doubles when HiDPI)
        res.width = UInt32(w)
        res.height = UInt32(h)
        if !resolutions.contains(where: { $0.width == res.width && $0.height == res.height && $0.HiDPI == res.HiDPI }) {
            resolutions.append(res)
            resolutions.sort { $0.width > $1.width || ($0.width == $1.width && $0.height > $1.height) }
            tableView.reloadData()
        }
        widthField.stringValue = ""
        heightField.stringValue = ""
        updatePreview()
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard row >= 0 && row < resolutions.count else { return }
        resolutions.remove(at: row)
        tableView.reloadData()
    }

    @objc private func save() {
        if let error = store.save(resolutions) {
            NSAlert(fromDict: error).beginSheetModal(for: view.window!)
        } else {
            view.window?.close()
        }
    }

    @objc private func cancel() {
        view.window?.close()
    }
}

private extension NSBox {
    static func hSeparator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}
