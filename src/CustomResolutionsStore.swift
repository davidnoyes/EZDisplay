//
//  CustomResolutionsStore.swift
//  EZDisplay
//
//  Reads and writes a display's custom scaled resolutions in its display-override
//  plist (/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-x/
//  DisplayProductID-x). Extracted from the old storyboard ViewController so the
//  persistence is independent of any UI.
//

import Foundation

class CustomResolutionsStore {

    let vendorID: UInt32
    let productID: UInt32
    let displayName: String

    private let kScaleResolutionsKey = "scale-resolutions"
    private let kTargetPPMMKey       = "target-default-ppmm"
    private let kDisplayProductName  = "DisplayProductName"

    // Provenance markers. The override directory is shared with other tools, so
    // teardown has to know which files are EZDisplay's before deleting anything. These
    // are reverse-DNS namespaced to avoid colliding with Apple's keys, and macOS
    // ignores keys it does not recognise.
    static let kManagedKey     = "io.github.davidnoyes.ezdisplay.managed"
    static let kCreatedFileKey = "io.github.davidnoyes.ezdisplay.created-file"

    // Preserves any other keys already in the display's override plist.
    private var plist = NSMutableDictionary()

    // /Library/Displays was added in a Catalina update; older systems (and any
    // system with SIP off) write under /System instead.
    static let supportsLibraryDisplays = ProcessInfo().isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 10, minorVersion: 15, patchVersion: 0))
    static let rootWriteable = !supportsLibraryDisplays && !isSIPActive()
    static let rootdir    = "/Library/Displays/Contents/Resources/Overrides"
    static let dirformat  = "DisplayVendorID-%x"
    static let fileformat = "DisplayProductID-%x"

    init(vendorID: UInt32, productID: UInt32, displayName: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.displayName = displayName
    }

    private var sourceDirs: [String] {
        let srcDir = String(format: "\(CustomResolutionsStore.rootdir)/\(CustomResolutionsStore.dirformat)", vendorID)
        return CustomResolutionsStore.supportsLibraryDisplays ? [srcDir, "/System" + srcDir] : ["/System" + srcDir]
    }
    private var sourceFiles: [String] {
        sourceDirs.map { String(format: "\($0)/\(CustomResolutionsStore.fileformat)", productID) }
    }
    private var destinationDir: String {
        let dstDir = String(format: "\(CustomResolutionsStore.rootdir)/\(CustomResolutionsStore.dirformat)", vendorID)
        return CustomResolutionsStore.supportsLibraryDisplays ? dstDir : "/System" + dstDir
    }
    private var destinationFile: String {
        String(format: "\(destinationDir)/\(CustomResolutionsStore.fileformat)", productID)
    }

    /// The display's currently-defined custom scaled resolutions. Low-DPI
    /// counterparts of HiDPI entries are hidden (the UI only edits the "logical"
    /// resolutions the user thinks in).
    func load() -> [Resolution] {
        plist = sourceFiles.compactMap { NSMutableDictionary(contentsOfFile: $0) }.first ?? NSMutableDictionary()

        var resolutions: [Resolution] = []
        if let array = plist[kScaleResolutionsKey] as? NSArray {
            resolutions.append(contentsOf: array.map { Resolution(nsdata: $0 as? NSData) })
        }
        resolutions = resolutions.filter { res in
            !(res.RawFlags == 0 &&
              resolutions.contains(where: { $0.HiDPI && $0.height * 2 == res.height && $0.width * 2 == res.width }))
        }
        return Array(NSOrderedSet(array: resolutions)) as! [Resolution]
    }

    /// Persist `resolutions` to the override plist (admin auth required; effective
    /// after logout/reboot). Returns an AppleScript error dictionary, or nil on
    /// success. Regenerates the low-DPI counterparts macOS expects.
    func save(_ resolutions: [Resolution]) -> NSDictionary? {
        if let error = RestoreSettingsItem.backupSettings(originalPlistPath: sourceFiles.last!) {
            return error
        }

        plist[kDisplayProductName] = displayName as NSString

        // Record provenance before writing. `created-file` is decided once, on the
        // first write, and carried forward by `load()` on every later save: if the
        // destination already existed then the file belongs to something else and
        // EZDisplay is only adding to it, so teardown must not delete it.
        let createdHere = (plist[CustomResolutionsStore.kCreatedFileKey] as? Bool)
            ?? !FileManager.default.fileExists(atPath: destinationFile)
        plist[CustomResolutionsStore.kManagedKey]     = true
        plist[CustomResolutionsStore.kCreatedFileKey] = createdHere

        let sorted = resolutions.sorted { $0.width > $1.width || ($0.width == $1.width && $0.height > $1.height) }
        let hiDPI  = sorted.filter { $0.RawFlags & kFlagHiDPI != 0 }
        let lowDPI = sorted.filter { $0.RawFlags & kFlagHiDPI == 0 }
        let counterparts = hiDPI.map { r -> Resolution in
            let res = Resolution()
            res.width  = r.width * 2
            res.height = r.height * 2
            res.RawFlags = 0
            return res
        }
        let finalResolutions = lowDPI + counterparts + hiDPI

        plist[kScaleResolutionsKey] = finalResolutions.map { $0.toData() } as NSArray
        if plist[kTargetPPMMKey] == nil {
            plist[kTargetPPMMKey] = 10.01
        }

        let tmpFile = NSTemporaryDirectory() + UUID().uuidString
        plist.write(toFile: tmpFile, atomically: false)

        let scripts = [
            "mkdir -p \(shellQuoted(destinationDir))",
            "cp \(shellQuoted(tmpFile)) \(shellQuoted(destinationFile))",
            "rm \(shellQuoted(tmpFile))",
        ]
        return NSAppleScript.executeAndReturnError(source: scripts.joined(separator: " && "),
                                                   asType: .shell, withAdminPriv: true)
    }
}
