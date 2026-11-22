import Foundation
import Observation

/// The sidebar destinations a meeting can be opened from.
enum DetailSection: Equatable {
    case today, ask, insights, radar

    var title: String {
        switch self {
        case .today: L10n.text("Today")
        case .ask: L10n.text("Ask")
        case .insights: L10n.text("Insights")
        case .radar: L10n.text("Radar")
        }
    }
}

extension Route {
    var section: DetailSection? {
        switch self {
        case .library: .today
        case .ask: .ask
        case .insights: .insights
        case .commitments: .radar
        case .meeting, .recording, .recordingRecovery: nil
        }
    }
}

/// Back and forward through the detail pane's destinations, like a browser.
/// Every route change is recorded except the ones back and forward make.
struct DetailNavigationHistory: Equatable {
    enum Direction { case back, forward }

    static let limit = 50

    private(set) var back: [Route] = []
    private(set) var forward: [Route] = []
    private var stepping: Route?

    mutating func record(from old: Route?, to new: Route?) {
        let old = old ?? .library, new = new ?? .library
        let stepped = stepping == new
        stepping = nil
        guard !stepped, old != new else { return }
        back.append(old)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// The nearest destination that still exists in that direction; entries
    /// passed over (a deleted meeting) are dropped.
    mutating func step(_ direction: Direction, from current: Route?, isAvailable: (Route) -> Bool) -> Route? {
        let current = current ?? .library
        stepping = direction == .back
            ? Self.step(from: &back, to: &forward, current: current, isAvailable: isAvailable)
            : Self.step(from: &forward, to: &back, current: current, isAvailable: isAvailable)
        return stepping
    }

    /// Where a meeting was opened from: the nearest earlier destination that
    /// is not another meeting or a recording, with its focus, else Today.
    var origin: (section: DetailSection, route: Route) {
        back.reversed().lazy.compactMap { route in route.section.map { ($0, route) } }.first ?? (.today, .library)
    }

    private static func step(
        from source: inout [Route], to target: inout [Route], current: Route, isAvailable: (Route) -> Bool
    ) -> Route? {
        while let candidate = source.popLast() {
            guard isAvailable(candidate), candidate != current else { continue }
            target.append(current)
            return candidate
        }
        return nil
    }
}

/// The window's history, shared by reference so the meeting page re-renders
/// only its title bar when it changes.
@MainActor @Observable
final class DetailNavigation {
    private(set) var history = DetailNavigationHistory()
    @ObservationIgnored private let isAvailable: (Route) -> Bool

    init(isAvailable: @escaping (Route) -> Bool) {
        self.isAvailable = isAvailable
    }

    func record(from old: Route?, to new: Route?) {
        history.record(from: old, to: new)
    }

    func canStep(_ direction: DetailNavigationHistory.Direction, from current: Route?) -> Bool {
        let current = current ?? .library
        return (direction == .back ? history.back : history.forward).contains { $0 != current && isAvailable($0) }
    }

    func step(_ direction: DetailNavigationHistory.Direction, route: inout Route?) {
        if let next = history.step(direction, from: route, isAvailable: isAvailable) { route = next }
    }
}
