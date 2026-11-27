import Foundation

/// Each voice's turns: runs of its rows that no other voice's row starts inside.
enum VoiceTurnRuns {
    /// - Parameter rows: sorted by start.
    /// - Returns: voices in first-heard order and their turns in time order.
    static func merge<Key: Hashable>(
        _ rows: [(key: Key, start: TimeInterval, end: TimeInterval)]
    ) -> (order: [Key], turns: [Key: [ClosedRange<TimeInterval>]]) {
        var order: [Key] = []
        var turns: [Key: [ClosedRange<TimeInterval>]] = [:]
        var previous: Key?
        for row in rows {
            if previous == row.key, let last = turns[row.key]?.indices.last {
                let run = turns[row.key]![last]
                turns[row.key]![last] = run.lowerBound...max(run.upperBound, row.end)
            } else {
                if turns[row.key] == nil { order.append(row.key) }
                turns[row.key, default: []].append(row.start...row.end)
            }
            previous = row.key
        }
        return (order, turns)
    }
}
