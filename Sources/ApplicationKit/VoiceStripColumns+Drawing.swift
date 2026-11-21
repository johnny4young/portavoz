import Foundation
import PortavozCore

extension VoiceColumns {
    /// Consecutive columns held by one voice; `end` is exclusive.
    public struct Run: Sendable, Equatable {
        public let voice: UInt8
        public let start: Int
        public let end: Int

        public init(voice: UInt8, start: Int, end: Int) {
            self.voice = voice
            self.start = start
            self.end = end
        }
    }

    /// Folds stored columns down to `count` by the binning rule, each run of
    /// one voice standing in for a turn. A strip already at or under `count`
    /// comes back as is.
    public static func resampled(_ columns: [UInt8], count: Int) -> [UInt8] {
        guard count > 0, !columns.isEmpty else { return [] }
        guard count < columns.count else { return columns }
        let turns = runs(columns).map {
            Turn(voice: Int($0.voice), start: Double($0.start), end: Double($0.end))
        }
        return bin(turns, duration: Double(columns.count), count: count)
    }

    /// Run-length encoding of the voiced columns; silence yields no run.
    public static func runs(_ columns: [UInt8]) -> [Run] {
        var runs: [Run] = []
        var index = 0
        while index < columns.count {
            let voice = columns[index]
            var end = index + 1
            while end < columns.count, columns[end] == voice { end += 1 }
            if voice != silence { runs.append(Run(voice: voice, start: index, end: end)) }
            index = end
        }
        return runs
    }
}
