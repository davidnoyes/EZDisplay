//
//  RestoreSettingsTests.swift
//  EZDisplay
//
//  Tests for the provenance check in src/RestoreSettings.swift.
//
//  Every override file lives in a directory shared with other tools, so what
//  this check answers decides whether a file is deleted or left alone. It has
//  to fail closed: only a file carrying both markers is ours, and everything
//  else — unmarked, half-marked, unreadable, absent — is somebody's settings
//  that this app must not touch.
//
//  These tests write plists to a temporary directory and read them straight
//  back. Nothing here goes near the real override directory, and nothing here
//  deletes anything.
//

import XCTest

final class OverrideProvenanceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EZDisplayProvenanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    /// Writes `contents` as an override plist and returns its path.
    private func override(_ contents: [String: Any]) -> String {
        let path = scratch.appendingPathComponent("DisplayProductID-abcd").path
        XCTAssertTrue((contents as NSDictionary).write(toFile: path, atomically: true))
        return path
    }

    func testAFileCarryingBothMarkersIsOursToDelete() {
        let marks = RestoreSettingsItem.provenance(ofOverrideAt: override([
            CustomResolutionsStore.kManagedKey: true,
            CustomResolutionsStore.kCreatedFileKey: true
        ]))

        XCTAssertTrue(marks.managed)
        XCTAssertTrue(marks.createdHere)
    }

    func testAFileThisAppOnlyEditedIsNotOursToDelete() {
        // The app added resolutions to a file another tool created. Removing it
        // would take that tool's settings with it.
        let marks = RestoreSettingsItem.provenance(ofOverrideAt: override([
            CustomResolutionsStore.kManagedKey: true,
            CustomResolutionsStore.kCreatedFileKey: false
        ]))

        XCTAssertTrue(marks.managed)
        XCTAssertFalse(marks.createdHere)
    }

    func testAnUnmarkedFileReadsAsNotOurs() {
        // Written by another tool outright, or by a build predating the markers.
        // Either way the answer has to be no.
        let marks = RestoreSettingsItem.provenance(ofOverrideAt: override([
            "DisplayProductName": "Some Display"
        ]))

        XCTAssertFalse(marks.managed)
        XCTAssertFalse(marks.createdHere)
    }

    func testAMarkerUnderAnyOtherKeyDoesNotCount() {
        // The keys are namespaced on the bundle identifier, so a marker written
        // under a different one is another app's claim, not this app's.
        let marks = RestoreSettingsItem.provenance(ofOverrideAt: override([
            "com.example.other.managed": true,
            "com.example.other.created-file": true
        ]))

        XCTAssertFalse(marks.managed)
        XCTAssertFalse(marks.createdHere)
    }

    func testAMissingFileReadsAsNotOurs() {
        let marks = RestoreSettingsItem.provenance(
            ofOverrideAt: scratch.appendingPathComponent("no-such-file").path)

        XCTAssertFalse(marks.managed)
        XCTAssertFalse(marks.createdHere)
    }

    func testAFileThatIsNotAPlistReadsAsNotOurs() {
        let path = scratch.appendingPathComponent("DisplayProductID-abcd").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path,
                                                     contents: Data("not a plist".utf8)))

        let marks = RestoreSettingsItem.provenance(ofOverrideAt: path)

        XCTAssertFalse(marks.managed)
        XCTAssertFalse(marks.createdHere)
    }
}

/// `restoreAllScript(for:)` is what actually runs under an administrator
/// password, so what it does with an empty or non-existent list matters: a
/// script built from nothing must be nil rather than a command with no
/// arguments.
final class RestoreAllScriptTests: XCTestCase {
    func testAnEmptyListProducesNoScript() {
        XCTAssertNil(RestoreSettingsItem.restoreAllScript(for: []))
    }

    func testAPathWithNoFileBehindItProducesNoScript() {
        // The sweep reads the directory first, so a path can disappear between
        // being listed and being removed. It must drop out rather than become a
        // command that fails under authorisation.
        let absent = "DisplayVendorID-ffffffff/DisplayProductID-ffffffff"
        XCTAssertNil(RestoreSettingsItem.restoreAllScript(for: [absent]))
    }
}
