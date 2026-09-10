//
//  RestoreSettings.swift
//
//  Undoing the display overrides this app writes.
//
//  There are two undos. A display's own menu item restores just that display:
//  put back the backup taken before the app first touched the file, then remove
//  the override. "Restore all" sweeps every override the app owns — including
//  displays that are not plugged in right now — in a single authorized batch.
//
//  Both run as shell scripts under `do shell script`, because the override
//  directory is not writable by the user.
//

import Cocoa

@objc class RestoreSettingsItem: NSMenuItem {
    @objc var vendorID: UInt32
    @objc var productID: UInt32
    @objc var displayName: String

    /// This display's override, relative to the override root.
    var filePath: String

    /// Where the pre-existing override plists are copied before the app edits
    /// one. Keyed on the bundle identifier, so a backup taken by one build is
    /// not visible to a differently identified one.
    private static let backupDir =
        getAppSupportDir(withTrailingPath: "\(Bundle.main.bundleIdentifier!)/Backups")

    @objc init(title: String,
               action: Selector,
               vendorID: UInt32,
               productID: UInt32,
               displayName: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.displayName = displayName
        self.filePath = String(format: "\(CustomResolutionsStore.dirformat)/\(CustomResolutionsStore.fileformat)",
                               vendorID, productID)

        super.init(title: title, action: action, keyEquivalent: "")
    }

    // The menu is built in code, so there is no archive to decode one of these
    // from.
    required init(coder decoder: NSCoder) {
        fatalError("RestoreSettingsItem is not loadable from an archive")
    }

    /// Copies a display's override plist aside before the app edits it, so the
    /// original settings can be put back later.
    ///
    /// Does nothing and returns nil when a backup already exists — the first
    /// one taken is the only one that holds the pre-app state — or when there
    /// is no file to copy, which is the usual case: most displays have no
    /// override until this app writes one.
    static func backupSettings(originalPlistPath: String) -> NSDictionary? {
        let fm = FileManager.default

        // The last two components are `DisplayVendorID-x/DisplayProductID-y`,
        // and the backup tree mirrors that shape.
        let tail = URL(fileURLWithPath: originalPlistPath).pathComponents.suffix(2)
        guard let vendorDir = tail.first, let plistName = tail.last else { return nil }

        let backupVendorDir = backupDir.appendingPathComponent(vendorDir).standardizedFileURL
        let backupPlist = backupVendorDir.appendingPathComponent(plistName).standardizedFileURL.path

        guard !fm.fileExists(atPath: backupPlist),
              fm.fileExists(atPath: originalPlistPath) else { return nil }

        let script = "mkdir -p \(shellQuoted(backupVendorDir.path))"
            + " && cp \(shellQuoted(originalPlistPath)) \(shellQuoted(backupPlist))"

        return NSAppleScript.executeAndReturnError(source: script, asType: .shell)
    }

    /// Every `DisplayVendorID-x/DisplayProductID-y` file in the shared override
    /// directory, whoever wrote it.
    private static func allOverrideRelativePaths() -> [String] {
        let fm = FileManager.default
        let root = CustomResolutionsStore.rootdir
        var paths: [String] = []

        let vendors = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted()
        for vendor in vendors where vendor.hasPrefix("DisplayVendorID-") {
            let products = ((try? fm.contentsOfDirectory(atPath: "\(root)/\(vendor)")) ?? []).sorted()
            for product in products where product.hasPrefix("DisplayProductID-") {
                paths.append("\(vendor)/\(product)")
            }
        }
        return paths
    }

    /// Reads the provenance markers this app stamps into an override plist on
    /// save. An unmarked file — anything written by another tool, or by a build
    /// predating these markers — reads as not managed, so it is left alone.
    ///
    /// Deliberately not private: this is the one check standing between "delete
    /// the file" and "leave someone else's settings alone", so the tests call it
    /// directly rather than through the two sweeps that read a system directory.
    static func provenance(ofOverrideAt path: String) -> (managed: Bool, createdHere: Bool) {
        guard let plist = NSDictionary(contentsOfFile: path) else { return (false, false) }
        return ((plist[CustomResolutionsStore.kManagedKey] as? Bool) ?? false,
                (plist[CustomResolutionsStore.kCreatedFileKey] as? Bool) ?? false)
    }

    /// Override files this app created and therefore owns outright. Only these
    /// are safe to delete: nothing else has settings in them to lose.
    @objc static func managedOverrideRelativePaths() -> [String] {
        return allOverrideRelativePaths().filter {
            let marks = provenance(ofOverrideAt: "\(CustomResolutionsStore.rootdir)/\($0)")
            return marks.managed && marks.createdHere
        }
    }

    /// Override files that are present but not this app's to delete, for either
    /// reason: another tool created the file and this app only added
    /// resolutions to it, or the file carries no markers at all — written by
    /// another tool outright, or by a build predating these markers. Deleting
    /// either could destroy settings this app never made, so they are reported
    /// to the user instead of removed.
    @objc static func unmanagedOverrideRelativePaths() -> [String] {
        return allOverrideRelativePaths().filter {
            let marks = provenance(ofOverrideAt: "\(CustomResolutionsStore.rootdir)/\($0)")
            return !(marks.managed && marks.createdHere)
        }
    }

    /// The shell commands that delete the override files in `relativePaths`, or
    /// nil when there is nothing to undo. Building the script is kept separate
    /// from running it so it can be inspected without administrator
    /// authorization. Pass only paths from `managedOverrideRelativePaths()`.
    @objc static func restoreAllScript(for relativePaths: [String]) -> String? {
        let fm = FileManager.default
        let removals = relativePaths.compactMap { relativePath -> String? in
            let override = "\(CustomResolutionsStore.rootdir)/\(relativePath)"
            guard fm.fileExists(atPath: override) else { return nil }
            return "rm -f \(shellQuoted(override))"
        }

        return removals.isEmpty ? nil : removals.joined(separator: " && ")
    }

    /// Undoes the display overrides for every display this app has touched,
    /// including ones that are not currently connected, in a single
    /// administrator-authorized batch. Returns an AppleScript error dictionary,
    /// or nil when the restore succeeded or there was nothing to do.
    @objc static func restoreAllSettings() -> NSDictionary? {
        guard let script = restoreAllScript(for: managedOverrideRelativePaths()) else { return nil }
        return NSAppleScript.executeAndReturnError(source: script, asType: .shell, withAdminPriv: true)
    }

    /// Puts this one display back: restore the backup first where the app wrote
    /// into a file that was already there, then drop the override itself.
    @objc func restoreSettings() -> NSDictionary? {
        let fm = FileManager.default
        let override = "\(CustomResolutionsStore.rootdir)/\(filePath)"
        let backup = RestoreSettingsItem.backupDir.appendingPathComponent(filePath)
            .standardizedFileURL.path

        var steps = [String]()

        if !CustomResolutionsStore.supportsLibraryDisplays
            && CustomResolutionsStore.rootWriteable
            && fm.fileExists(atPath: backup) {
            steps.append("cp -f \(shellQuoted(backup)) \(shellQuoted("/System\(override)"))")
        }

        if fm.fileExists(atPath: override) {
            steps.append("rm -f \(shellQuoted(override))")
        }

        guard !steps.isEmpty else { return nil }

        return NSAppleScript.executeAndReturnError(source: steps.joined(separator: " && "),
                                                   asType: .shell,
                                                   withAdminPriv: true)
    }
}
