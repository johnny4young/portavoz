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

struct SettingsWindowCapture: NSViewControllerRepresentable {
    let reference: SettingsWindowReference

    func makeNSViewController(context: Context) -> SettingsWindowCaptureController {
        SettingsWindowCaptureController(reference: reference)
    }

    func updateNSViewController(
        _ controller: SettingsWindowCaptureController,
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
    }
}

@MainActor
final class SettingsWindowCaptureController: NSViewController {
    private let reference: SettingsWindowReference
    private let position: @MainActor (NSWindow) -> Void

    init(
        reference: SettingsWindowReference,
        position: @escaping @MainActor (NSWindow) -> Void = UITestWindowPlacement.positionSettingsWindow
    ) {
        self.reference = reference
        self.position = position
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = SettingsWindowCaptureView(reference: reference)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // SwiftUI placement and AppKit frame restoration happen after view
        // attachment. Position only after presentation, using the final size.
        if let window = view.window { position(window) }
    }
}
