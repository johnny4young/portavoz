import AppKit
import SwiftUI

/// macOS 14 has no SwiftUI scroll-phase callback. This zero-size bridge lives
/// inside the ScrollView document hierarchy and observes AppKit's user-only
/// live-scroll notification for that exact enclosing scroll view. The
/// did-live signal also covers legacy mouse wheels that have no start/end
/// notification pair. Programmatic `ScrollViewProxy.scrollTo` calls do not
/// emit the notification.
struct LegacyScrollInteractionTracker: NSViewRepresentable {
    let onInteraction: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInteraction: onInteraction)
    }

    func makeNSView(context: Context) -> LocatorView {
        let view = LocatorView()
        view.coordinator = context.coordinator
        view.locateEnclosingScrollView()
        return view
    }

    func updateNSView(_ view: LocatorView, context: Context) {
        context.coordinator.onInteraction = onInteraction
        view.coordinator = context.coordinator
        view.locateEnclosingScrollView()
    }

    static func dismantleNSView(_ view: LocatorView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onInteraction: @MainActor () -> Void
        private weak var scrollView: NSScrollView?

        init(onInteraction: @escaping @MainActor () -> Void) {
            self.onInteraction = onInteraction
        }

        func connect(to scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else { return }
            disconnect()
            self.scrollView = scrollView
            guard let scrollView else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userDidLiveScroll),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView)
        }

        func disconnect() {
            if let scrollView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSScrollView.didLiveScrollNotification,
                    object: scrollView)
            }
            scrollView = nil
        }

        @objc private func userDidLiveScroll(_ notification: Notification) {
            onInteraction()
        }
    }

    @MainActor
    final class LocatorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            locateEnclosingScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            locateEnclosingScrollView()
        }

        func locateEnclosingScrollView() {
            if let enclosingScrollView {
                coordinator?.connect(to: enclosingScrollView)
                return
            }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                coordinator?.connect(to: enclosingScrollView)
            }
        }
    }
}
