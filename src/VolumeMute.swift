//
//  VolumeMute.swift
//  EZDisplay
//
//  What a volume write should do to the display's mute state.
//
//  One function rather than two guards, because the two halves of this are the
//  same rule read in opposite directions and they have to agree. Muting does not
//  move the dial, so the display gives no sign of which state it is in and the
//  row's own record is the only one there is: a mute the row asks for twice, or
//  an unmute it never asks for, both end as a slider that moves while nothing
//  comes out — and that is not a fault anything reports, it is one someone
//  notices.
//
//  Kept out of `VolumeSliderItem` so a test can reach it. The row itself cannot
//  be tested — it is an NSMenuItem over a DDC bus — and this is the whole of it
//  that is a decision.
//

import Foundation

/// What to do about mute, alongside a volume write.
enum EZVolumeMuteAction {
    /// The display's mute state is already right for the volume being written.
    case leaveAlone
    /// Lift it: the volume is being moved somewhere audible.
    case unmute
    /// Set it: the volume has reached the bottom and the option is on.
    case mute
}

enum EZVolumeMute {
    /// Given the volume about to be written, what the row last saw of mute, and
    /// whether **Mute the display when the volume reaches 0%** is on.
    ///
    /// `muted` is what stops either side repeating. The row updates it the
    /// moment it acts, so the rest of a drag — or of a held key — asks for
    /// nothing, and a display that refused the write is not asked again until
    /// something puts the row back.
    static func action(percent: Int, muted: Bool, muteAtZero: Bool) -> EZVolumeMuteAction {
        // Audible. Mute is lifted if it is set, whatever the option says: the
        // option is about the bottom of the dial, and letting it gate the unmute
        // as well would leave anyone who turned it on unable to get sound back.
        if percent > 0 { return muted ? .unmute : .leaveAlone }

        // Silent. Not an unmute — writing zero and lifting mute in the same
        // breath contradicts itself.
        guard muteAtZero, !muted else { return .leaveAlone }
        return .mute
    }
}
