import PortavozCore
import SwiftUI

#if canImport(Translation)
import Translation

/// Live translated captions (M6): a view modifier that keeps a
/// `TranslationSession` alive while recording and back-fills a
/// translation for every caption that lacks one. The OS may ask to
/// download the language pair on first use — that's the interactive bit
/// pending user verification.
@available(macOS 15.0, *)
struct LiveTranslationModifier: ViewModifier {
    @Bindable var controller: RecordingController

    private var configuration: TranslationSession.Configuration? {
        guard let target = controller.translationTarget else { return nil }
        return TranslationSession.Configuration(
            source: nil,  // auto-detect per caption
            target: Locale.Language(identifier: target)
        )
    }

    /// The SwiftUI overlay hands the session to a MainActor closure, but
    /// its async methods are nonisolated — under Swift 6 that's a region
    /// violation. Confinement: the box only ever lives inside the single
    /// translationTask task and the session is used serially there.
    private struct SessionBox: @unchecked Sendable {
        let session: TranslationSession
    }

    func body(content: Content) -> some View {
        let controller = self.controller
        return content.translationTask(configuration) { session in
            // The framework cancels this task when the configuration
            // changes or the view goes away.
            await Self.translationLoop(box: SessionBox(session: session), controller: controller)
        }
    }

    private nonisolated static func translationLoop(
        box: SessionBox, controller: RecordingController
    ) async {
        while !Task.isCancelled {
            let pending: [(id: UUID, text: String)] = await MainActor.run {
                // The newest row is still growing (the coalescer only ever
                // extends the last one) — translate rows once they're closed.
                let openID = controller.captions.last?.id
                return controller.captions.suffix(60)
                    .filter {
                        $0.id != openID && controller.translations[$0.id] == nil
                            && $0.text.count >= 4
                    }
                    .map { ($0.id, $0.text) }
            }
            if !pending.isEmpty {
                let requests = pending.map {
                    TranslationSession.Request(
                        sourceText: $0.text, clientIdentifier: $0.id.uuidString)
                }
                if let responses = try? await box.session.translations(from: requests) {
                    let translated: [(UUID, String)] = responses.compactMap { response in
                        guard
                            let identifier = response.clientIdentifier,
                            let id = UUID(uuidString: identifier)
                        else { return nil }
                        return (id, response.targetText)
                    }
                    await MainActor.run {
                        for (id, text) in translated {
                            controller.translations[id] = text
                        }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}
#endif

extension View {
    /// Applies live translation when the OS supports it; a no-op earlier.
    @ViewBuilder
    func liveTranslation(_ controller: RecordingController) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            modifier(LiveTranslationModifier(controller: controller))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
