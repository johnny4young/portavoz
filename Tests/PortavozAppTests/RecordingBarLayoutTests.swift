import AppKit
import Observation
import SwiftUI
import XCTest

@testable import portavoz_app

final class LevelBarFillTests: XCTestCase {
    func testTheFillCoversItsFractionOfTheTrack() {
        let track = CGRect(x: 0, y: 0, width: 90, height: 5)

        let half = LevelBarFill(fraction: 0.5).path(in: track).boundingRect
        XCTAssertEqual(half.minX, 0, accuracy: 0.01, "the fill grows from the leading edge")
        XCTAssertEqual(half.width, 45, accuracy: 0.01)
        XCTAssertEqual(half.height, 5, accuracy: 0.01)

        XCTAssertEqual(LevelBarFill(fraction: 3).path(in: track).boundingRect.width, 90, accuracy: 0.01)
        XCTAssertTrue(LevelBarFill(fraction: 0).path(in: track).isEmpty)
        XCTAssertTrue(LevelBarFill(fraction: -1).path(in: track).isEmpty)
        XCTAssertTrue(LevelBarFill(fraction: .nan).path(in: track).isEmpty)
    }

    func testTheMeterSpansSixtyDecibels() {
        XCTAssertEqual(LevelBarFill.fraction(forLevel: 0), 0)
        XCTAssertEqual(LevelBarFill.fraction(forLevel: 0.000_05), 0, "below the floor reads as silence")
        XCTAssertEqual(LevelBarFill.fraction(forLevel: 0.031_6), 0.5, accuracy: 0.01, "−30 dBFS is half the bar")
        XCTAssertEqual(LevelBarFill.fraction(forLevel: 1), 1)
        XCTAssertEqual(LevelBarFill.fraction(forLevel: 4), 1, "clipped input never overflows")
    }

    func testTheClockPlaceholderOnlyChangesWithTheDigitCount() {
        XCTAssertEqual(RecordingClockTemplate.placeholder(for: "07:42"), "00:00")
        XCTAssertEqual(RecordingClockTemplate.placeholder(for: "59:59"), "00:00")
        XCTAssertEqual(RecordingClockTemplate.placeholder(for: "100:03"), "000:00")
    }
}

/// A `ViewThatFits` re-measures every variant when anything inside one changes
/// its layout. The recording bar holds AppKit-backed controls in each variant,
/// so its clock and meter must repaint without reaching that measurement.
@MainActor
final class RecordingBarLayoutTests: XCTestCase {
    func testAClockTickDoesNotRemeasureTheRecordingBar() async throws {
        try skipUnlessTheProbeSeesLayoutChanges()
        let counter = LayoutMeasureCounter()
        let controller = RecordingController()
        let window = host(
            RecordingToolbar(
                controller: controller,
                companionAvailable: true,
                onStop: {},
                onCompact: {}),
            counter: counter)

        // The first tick lands before the baseline, the next two after it.
        try await Task.sleep(for: .milliseconds(1_200))
        await settle(window)
        let settled = counter.measures
        try await Task.sleep(for: .milliseconds(2_300))
        await settle(window)

        XCTAssertEqual(counter.measures, settled, "the clock re-measured the bar")
        XCTAssertFalse(window.isVisible, "unit tests must not open real host windows")
    }

    func testALevelSampleDoesNotRemeasureTheBarAroundTheMeter() async throws {
        try skipUnlessTheProbeSeesLayoutChanges()
        let counter = LayoutMeasureCounter()
        let model = LevelModel()
        let window = host(MeterBar(model: model, isolated: true), counter: counter)

        await settle(window)
        let settled = counter.measures
        for step in 1...10 {
            model.level = CGFloat(step % 7) / 7
            await settle(window)
        }

        XCTAssertEqual(counter.measures, settled, "a level sample re-measured the bar")
    }

    /// The same meter with the fill placed in the stack is re-measured on this
    /// OS. If a later SwiftUI stops doing that, the assertions above no longer
    /// prove anything and are skipped instead of passing vacuously.
    private func skipUnlessTheProbeSeesLayoutChanges() throws {
        let counter = LayoutMeasureCounter()
        let model = LevelModel()
        let window = host(MeterBar(model: model, isolated: false), counter: counter)
        window.contentView?.layoutSubtreeIfNeeded()
        let settled = counter.measures
        model.level = 0.9
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
        try XCTSkipUnless(
            counter.measures > settled,
            "SwiftUI no longer re-measures for a changed shape; the probe cannot see regressions")
    }

    private func host(_ content: some View, counter: LayoutMeasureCounter) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LayoutMeasureProbe(counter: counter) { content }
                .frame(width: 1_000))
        return window
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
private final class LayoutMeasureCounter {
    var measures = 0
}

/// Counts how often SwiftUI asks for the size of what it wraps: an
/// invalidation anywhere below reaches it.
private struct LayoutMeasureProbe: Layout {
    let counter: LayoutMeasureCounter

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated { counter.measures += 1 }
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: proposal)
    }
}

@MainActor
@Observable
private final class LevelModel {
    var level: CGFloat = 0.2
}

/// The recording bar's shape: two variants that both hold the meter.
private struct MeterBar: View {
    let model: LevelModel
    let isolated: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { meter; Spacer(minLength: 12); Button("Stop") {} }
            VStack { meter; Button("Stop") {} }
        }
    }

    @ViewBuilder
    private var meter: some View {
        if isolated {
            Capsule()
                .fill(.quaternary)
                .frame(width: 90, height: 5)
                .overlay { IsolatedFill(model: model) }
        } else {
            StackedFill(model: model)
        }
    }
}

private struct IsolatedFill: View {
    let model: LevelModel

    var body: some View {
        LevelBarFill(fraction: model.level)
            .fill(.green)
            .animation(.easeOut(duration: 0.15), value: model.level)
    }
}

private struct StackedFill: View {
    let model: LevelModel

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            LevelBarFill(fraction: model.level).fill(.green)
        }
        .frame(width: 90, height: 5)
    }
}
