import AppKit
import ApplicationKit
import SwiftUI

/// Keeps the imperative Settings-to-main-window transition at one narrow
/// AppKit boundary. The receipt destination is inert: this helper only routes
/// to the owning content and never invokes a Skill effect.
@MainActor
enum SettingsSkillReceiptNavigation {
    static func open(
        _ destination: SkillOfferReviewDestination,
        services: AppServices,
        settingsWindow: NSWindow?,
        openPrimaryWindow: () -> Void
    ) {
        switch destination {
        case .meeting(let meetingID):
            services.pendingRoute = .meeting(meetingID)
        case .commitment(let commitmentID):
            services.pendingRoute = .commitments(.commitment(commitmentID))
        case .residentMenuBar:
            return
        }

        openPrimaryWindow()
        settingsWindow?.close()
    }
}

@MainActor
final class SettingsWindowReference {
    weak var window: NSWindow?
}

struct SettingsWindowCapture: NSViewRepresentable {
    let reference: SettingsWindowReference

    func makeNSView(context: Context) -> SettingsWindowCaptureView {
        SettingsWindowCaptureView(reference: reference)
    }

    func updateNSView(
        _ nsView: SettingsWindowCaptureView,
        context: Context
    ) {}
}

@MainActor
final class SettingsWindowCaptureView: NSView {
    let reference: SettingsWindowReference

    init(reference: SettingsWindowReference) {
        self.reference = reference
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reference.window = window
        if let window {
            UITestWindowPlacement.positionSettingsWindow(window)
        }
    }
}
