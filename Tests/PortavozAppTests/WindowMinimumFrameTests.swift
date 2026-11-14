import AppKit
import Observation
import SwiftUI
import XCTest

@testable import portavoz_app

/// AppKit recomputes a hosted window's minimum size whenever its content
/// changes. The root must answer that query without measuring the content.
@MainActor
final class WindowMinimumFrameTests: XCTestCase {
    func testAContentChangeNeverMeasuresTheContentForTheMinimum() async throws {
        try skipUnlessAPlainMinimumFrameIsMeasured()
        let recorder = ProposalRecorder()
        let model = CaptionModel()
        let (window, hosting) = host(
            ProbedContent(model: model, recorder: recorder)
                .windowMinimumSize(width: 900, height: 560))

        settle(hosting)
        recorder.minimumQueries = 0
        for step in 1...5 {
            model.text = String(repeating: "caption ", count: step * 20)
            settle(hosting)
        }

        XCTAssertEqual(recorder.minimumQueries, 0, "the minimum query measured the content")
        let sizing = NSHostingController(
            rootView: ProbedContent(model: model, recorder: recorder).windowMinimumSize(width: 900, height: 560))
        XCTAssertEqual(sizing.sizeThatFits(in: .zero), CGSize(width: 900, height: 560))
        XCTAssertFalse(window.isVisible, "unit tests must not open real host windows")
    }

    /// Without the layout, the same content is measured for the minimum on this
    /// OS. If a later SwiftUI stops doing that, the assertion above proves
    /// nothing and is skipped instead of passing vacuously.
    private func skipUnlessAPlainMinimumFrameIsMeasured() throws {
        let recorder = ProposalRecorder()
        let model = CaptionModel()
        let (_, hosting) = host(
            ProbedContent(model: model, recorder: recorder)
                .frame(minWidth: 900, minHeight: 560))
        settle(hosting)
        recorder.minimumQueries = 0
        model.text = String(repeating: "caption ", count: 40)
        settle(hosting)
        try XCTSkipUnless(
            recorder.minimumQueries > 0,
            "SwiftUI no longer measures content for the window minimum; the probe cannot see regressions")
    }

    private func host(_ content: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        return (window, hosting)
    }

    private func settle(_ hosting: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        hosting.updateConstraintsForSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class ProposalRecorder {
    var minimumQueries = 0
}

@MainActor
@Observable
private final class CaptionModel {
    var text = "caption"
}

private struct ProbedContent: View {
    let model: CaptionModel
    let recorder: ProposalRecorder

    var body: some View {
        ProposalProbe(recorder: recorder) {
            VStack {
                ViewThatFits(in: .horizontal) {
                    HStack { Text("Recording"); Spacer(minLength: 12); Button("Stop") {} }
                    VStack { Text("Recording"); Button("Stop") {} }
                }
                Text(model.text)
            }
        }
    }
}

/// Records the proposals that reach the content, counting the small ones a
/// minimum-size query sends.
private struct ProposalProbe: Layout {
    let recorder: ProposalRecorder

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if (proposal.width ?? .infinity) <= 900, (proposal.height ?? .infinity) <= 560 {
            MainActor.assumeIsolated { recorder.minimumQueries += 1 }
        }
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: proposal)
    }
}
