//
//  ResolutionTests.swift
//  EZDisplay
//
//  Tests for src/Resolution.swift: the big-endian word format a display
//  override plist stores one scaled resolution in, and the doubling that hides
//  behind the HiDPI flag.
//
//  This file is entirely pure — no display, no plist on disk, no privileged
//  write — so all of it belongs here rather than behind a scratch probe. The
//  byte patterns are written out literally rather than computed from the same
//  shifts the source uses, so a mistake in the shifting cannot agree with
//  itself.
//

import XCTest

/// A HiDPI entry stores twice the size the user asked for, so the two sizes
/// have to stay in step through every path that can change either one.
final class ResolutionSizeTests: XCTestCase {
    func testAHiDPIEntryReportsHalfWhatItStores() {
        // 1920x1080 stored as 3840x2160: four words, the third carrying the
        // HiDPI bit in the high half.
        let resolution = Resolution(nsdata: bytes(0, 0, 0x0F, 0, 0, 0, 0x08, 0x70,
                                                  0, 0, 0, 1) as NSData)
        XCTAssertTrue(resolution.HiDPI)
        XCTAssertEqual(resolution.width, 1920)
        XCTAssertEqual(resolution.height, 1080)
    }

    func testAStandardEntryReportsWhatItStores() {
        let resolution = Resolution(nsdata: bytes(0, 0, 0x07, 0x80,
                                                  0, 0, 0x04, 0x38) as NSData)
        XCTAssertFalse(resolution.HiDPI)
        XCTAssertEqual(resolution.width, 1920)
        XCTAssertEqual(resolution.height, 1080)
    }

    func testSettingTheSizeOfAHiDPIEntryStoresTwiceIt() {
        let resolution = Resolution()   // HiDPI by default
        resolution.width = 1920
        resolution.height = 1080

        // Reading back gives what was set, not the doubled figure underneath.
        XCTAssertEqual(resolution.width, 1920)
        XCTAssertEqual(resolution.height, 1080)

        // The doubling shows up on disk, where macOS reads it.
        let written = [UInt8](resolution.toData() as Data)
        XCTAssertEqual(Array(written.prefix(8)),
                       [0, 0, 0x0F, 0, 0, 0, 0x08, 0x70])
    }

    func testTurningHiDPIOnKeepsTheSizeTheUserAskedFor() {
        // The stored numbers double, so that the resolution on screen does not
        // change when the flag does. Setting the flag afterwards is how the
        // command line's `custom add` avoids rescaling what it just set.
        let resolution = Resolution(nsdata: bytes(0, 0, 0x07, 0x80,
                                                  0, 0, 0x04, 0x38) as NSData)
        resolution.HiDPI = true

        XCTAssertEqual(resolution.width, 1920)
        XCTAssertEqual(resolution.height, 1080)
        XCTAssertEqual(Array([UInt8](resolution.toData() as Data).prefix(8)),
                       [0, 0, 0x0F, 0, 0, 0, 0x08, 0x70])
    }

    func testTurningHiDPIOffAlsoKeepsIt() {
        let resolution = Resolution()
        resolution.width = 1920
        resolution.height = 1080
        resolution.HiDPI = false

        XCTAssertEqual(resolution.width, 1920)
        XCTAssertEqual(resolution.height, 1080)
    }

    func testSettingTheSameFlagWordTwiceDoesNotRescale() {
        // Only a change in the HiDPI bit may move the stored size. A write that
        // leaves the bit where it was has to leave the numbers alone, or every
        // save would double them again.
        let resolution = Resolution()
        resolution.width = 1920
        let flags = resolution.RawFlags

        resolution.RawFlags = flags
        resolution.RawFlags = flags

        XCTAssertEqual(resolution.width, 1920)
    }
}

/// Trailing zero words are left off, matching what macOS itself writes.
final class ResolutionEncodingTests: XCTestCase {
    func testAFlaglessEntryIsTwoWords() {
        let resolution = Resolution(nsdata: bytes(0, 0, 0x07, 0x80,
                                                  0, 0, 0x04, 0x38) as NSData)
        XCTAssertEqual(resolution.RawFlags, 0)
        XCTAssertEqual([UInt8](resolution.toData() as Data),
                       [0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38])
    }

    func testFlagsInTheHighWordAloneDropTheLowWord() {
        let resolution = Resolution(nsdata: bytes(0, 0, 0x0F, 0,
                                                  0, 0, 0x08, 0x70,
                                                  0, 0, 0, 1) as NSData)
        XCTAssertEqual([UInt8](resolution.toData() as Data),
                       [0, 0, 0x0F, 0, 0, 0, 0x08, 0x70, 0, 0, 0, 1])
    }

    func testFlagsInTheLowWordKeepBothWords() {
        // The high word is written even though it is zero, because dropping it
        // would shift the low word into its place and change what it means.
        let resolution = Resolution(nsdata: bytes(0, 0, 0x07, 0x80,
                                                  0, 0, 0x04, 0x38,
                                                  0, 0, 0, 0,
                                                  0, 0x20, 0, 0) as NSData)
        XCTAssertEqual([UInt8](resolution.toData() as Data),
                       [0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38,
                        0, 0, 0, 0, 0, 0x20, 0, 0])
    }

    func testTheDefaultEntryCarriesRetinaHiDPIAndBit21() {
        let resolution = Resolution()
        XCTAssertEqual(resolution.RawFlags, 0x0000_0009_0020_0000)
        XCTAssertEqual([UInt8](resolution.toData() as Data),
                       [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0x20, 0, 0])
    }
}

final class ResolutionDecodingTests: XCTestCase {
    func testNoDataYieldsTheDefaultEntry() {
        XCTAssertEqual(Resolution(nsdata: nil), Resolution())
    }

    func testDataTooShortForAWidthAndHeightYieldsTheDefaultEntry() {
        // A malformed plist has to leave the editor usable, so a short entry is
        // a default rather than a failure to open.
        XCTAssertEqual(Resolution(nsdata: bytes(0, 0, 0x07) as NSData), Resolution())
        XCTAssertEqual(Resolution(nsdata: bytes(0, 0, 0x07, 0x80) as NSData), Resolution())
    }

    func testATrailingPartialWordIsIgnored() {
        // Three bytes short of a third word: the width and height still read.
        let resolution = Resolution(nsdata: bytes(0, 0, 0x07, 0x80,
                                                  0, 0, 0x04, 0x38,
                                                  0) as NSData)
        XCTAssertEqual(resolution.width, 1920)
        XCTAssertEqual(resolution.height, 1080)
        XCTAssertEqual(resolution.RawFlags, 0)
    }

    func testAWordIsReadBigEndianWhateverTheHostOrderIs() {
        // Assembled a byte at a time in the source, so this pins the order
        // rather than restating whatever the host happens to do.
        let resolution = Resolution(nsdata: bytes(0x01, 0x02, 0x03, 0x04,
                                                  0, 0, 0, 0) as NSData)
        XCTAssertEqual(resolution.width, 0x0102_0304)
    }
}

/// Loading and saving is what the editor does every time it opens, so an entry
/// another tool wrote has to come back out as it went in.
final class ResolutionRoundTripTests: XCTestCase {
    private func assertRoundTrips(_ input: [UInt8],
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let out = [UInt8](Resolution(nsdata: bytes(input) as NSData).toData() as Data)
        XCTAssertEqual(out, input, file: file, line: line)
    }

    func testAFlaglessEntrySurvives() {
        assertRoundTrips([0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38])
    }

    func testAHiDPIEntrySurvives() {
        assertRoundTrips([0, 0, 0x0F, 0, 0, 0, 0x08, 0x70, 0, 0, 0, 1])
    }

    func testAnEntryWithFlagsInBothWordsSurvives() {
        assertRoundTrips([0, 0, 0x0F, 0, 0, 0, 0x08, 0x70,
                          0, 0, 0, 9, 0, 0x20, 0, 0])
    }

    func testAnUnknownFlagBitIsCarriedRatherThanCleared() {
        // The bits this app does not act on still belong to whatever wrote
        // them, so a load-and-save must not quietly drop them.
        assertRoundTrips([0, 0, 0x0F, 0, 0, 0, 0x08, 0x70,
                          0x80, 0, 0, 0, 0, 0, 0, 0x40])
    }
}

final class ResolutionEqualityTests: XCTestCase {
    func testTwoEntriesWithTheSameBytesAreEqualAndHashAlike() {
        let a = Resolution(nsdata: bytes(0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38) as NSData)
        let b = Resolution(nsdata: bytes(0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38) as NSData)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hash, b.hash)
    }

    func testTheSameSizeAtDifferentFlagsIsADifferentEntry() {
        // A display can carry both a HiDPI and a standard entry at one size, so
        // the flags have to be part of identity. Were they not, adding one
        // would look like a duplicate of the other.
        let hiDPI = Resolution()
        hiDPI.width = 1920
        hiDPI.height = 1080

        let standard = Resolution()
        standard.HiDPI = false
        standard.width = 1920
        standard.height = 1080

        XCTAssertNotEqual(hiDPI, standard)
    }

    func testSomethingElseEntirelyIsNotEqual() {
        XCTAssertFalse(Resolution().isEqual("1920x1080"))
    }
}

private func bytes(_ values: UInt8...) -> Data { Data(values) }
private func bytes(_ values: [UInt8]) -> Data { Data(values) }
