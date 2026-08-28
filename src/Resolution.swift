//
//  Resolution.swift
//
//  One scaled resolution as a display override plist stores it.
//
//  On disk each entry is a run of big-endian 32-bit words: width, height, and
//  then up to two words of flags. Only the width and height are always present,
//  so both ends of the conversion treat everything after them as optional. The
//  file is written by hand rather than by an encoder because its shape is
//  dictated by what macOS reads back.
//

import Foundation

/// Flag bits carried by an override entry.
///
/// Only `hiDPI` has a meaning this app acts on. The rest are reproduced so an
/// entry written by something else survives a load-and-save round trip
/// unchanged, and they are named for the bit they occupy rather than for a
/// behavior, because their behavior is not documented anywhere.
let kFlagHiDPI: UInt64 = 0x0000_0001_0000_0000
let kFlagRetinaDisplay: UInt64 = 0x0000_0008_0000_0000
let kFlagBit21: UInt64 = 0x0000_0000_0020_0000

@objc class Resolution: NSObject {
    /// Width and height as macOS stores them, which for a HiDPI entry is twice
    /// the size the user asked for. The `width` and `height` properties convert
    /// in both directions, so callers deal only in the size that gets displayed.
    private var storedWidth: UInt32
    private var storedHeight: UInt32
    private var flags: UInt64

    private var scalesByTwo: Bool { flags & kFlagHiDPI != 0 }

    @objc dynamic var width: UInt32 {
        get { scalesByTwo ? storedWidth / 2 : storedWidth }
        set { storedWidth = scalesByTwo ? newValue &* 2 : newValue }
    }

    @objc dynamic var height: UInt32 {
        get { scalesByTwo ? storedHeight / 2 : storedHeight }
        set { storedHeight = scalesByTwo ? newValue &* 2 : newValue }
    }

    /// The whole flag word, as read from or written to the plist.
    ///
    /// Turning the HiDPI bit on or off rescales the stored size, so that the
    /// resolution the user sees stays put while the numbers underneath it
    /// change. Assigning a word that leaves the bit alone touches nothing else.
    @objc dynamic var RawFlags: UInt64 {
        get { flags }
        set {
            let wasScaled = scalesByTwo
            flags = newValue
            guard scalesByTwo != wasScaled else { return }

            if scalesByTwo {
                storedWidth &*= 2
                storedHeight &*= 2
            } else {
                storedWidth /= 2
                storedHeight /= 2
            }
        }
    }

    @objc dynamic var HiDPI: Bool {
        get { flags & kFlagHiDPI != 0 }
        set { RawFlags = newValue ? flags | kFlagHiDPI : flags & ~kFlagHiDPI }
    }

    /// A new entry, sized zero and flagged the way the editor offers by
    /// default: HiDPI, on a Retina display.
    override init() {
        storedWidth = 0
        storedHeight = 0
        flags = kFlagRetinaDisplay | kFlagHiDPI | kFlagBit21
        super.init()
    }

    private init(width: UInt32, height: UInt32, flags: UInt64) {
        self.storedWidth = width
        self.storedHeight = height
        self.flags = flags
        super.init()
    }

    /// Reads one entry back off disk.
    ///
    /// Anything too short to hold a width and a height is not an entry this app
    /// can use, so it yields a default rather than an error: a malformed plist
    /// should leave the editor usable, not stop it opening.
    convenience init(nsdata: NSData?) {
        let words = Resolution.bigEndianWords(nsdata as Data?)
        guard words.count >= 2 else {
            self.init()
            return
        }

        var flags: UInt64 = 0
        if words.count >= 3 { flags |= UInt64(words[2]) << 32 }
        if words.count >= 4 { flags |= UInt64(words[3]) }

        self.init(width: words[0], height: words[1], flags: flags)
    }

    /// Writes the entry back out.
    ///
    /// Trailing zero words are left off, matching what macOS itself writes: a
    /// flagless entry is four words shorter, and one whose flags fit in the
    /// high word omits the low one.
    func toData() -> NSData {
        var out = Data()
        Resolution.appendBigEndian(storedWidth, to: &out)
        Resolution.appendBigEndian(storedHeight, to: &out)

        if flags != 0 {
            Resolution.appendBigEndian(UInt32(truncatingIfNeeded: flags >> 32), to: &out)

            let low = UInt32(truncatingIfNeeded: flags)
            if low != 0 { Resolution.appendBigEndian(low, to: &out) }
        }

        return out as NSData
    }

    // MARK: Big-endian conversion

    /// Splits `data` into big-endian words, ignoring any trailing bytes that do
    /// not make up a whole one. Assembled a byte at a time on purpose: it costs
    /// nothing here, it is correct whatever the host's own byte order, and it
    /// does not care how the buffer happens to be aligned.
    private static func bigEndianWords(_ data: Data?) -> [UInt32] {
        guard let data else { return [] }
        let bytes = [UInt8](data)
        let wordCount = bytes.count / 4

        var words: [UInt32] = []
        words.reserveCapacity(wordCount)

        for word in 0 ..< wordCount {
            let first = word * 4
            var value = UInt32(bytes[first]) << 24
            value |= UInt32(bytes[first + 1]) << 16
            value |= UInt32(bytes[first + 2]) << 8
            value |= UInt32(bytes[first + 3])
            words.append(value)
        }

        return words
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    // MARK: Equality

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Resolution else { return false }

        return storedWidth == other.storedWidth
            && storedHeight == other.storedHeight
            && flags == other.flags
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(storedWidth)
        hasher.combine(storedHeight)
        hasher.combine(flags)
        return hasher.finalize()
    }
}
