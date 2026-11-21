import Foundation
import PortavozCore

/// A meeting's voice strip ready to draw: who held each time column and the
/// tint of every voice index, from the same cast the detail uses.
public struct VoiceStripColumns: Sendable, Equatable {
    /// Index into `tints` per column, or `VoiceColumns.silence`.
    public let columns: [UInt8]
    public let tints: [VoiceCast.Tint]
    public let cast: VoiceCast

    public init(columns: [UInt8], tints: [VoiceCast.Tint], cast: VoiceCast) {
        self.columns = columns
        self.tints = tints
        self.cast = cast
    }

    /// Nobody attributed yet: the strip draws only its track.
    public static let empty = VoiceStripColumns(
        columns: [], tints: [], cast: VoiceCast(members: [], ordering: .talkShare))
}
