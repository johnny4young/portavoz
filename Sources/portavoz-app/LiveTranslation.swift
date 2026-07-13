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

    private typealias Row = (id: UUID, text: String, source: String?)
    private typealias Ready = (id: UUID, text: String)

    nonisolated private static func translationLoop(
        box: SessionBox, controller: RecordingController
    ) async {
        // Within one task the target is constant (a picker change restarts
        // the translationTask). Cache each source→target availability so the
        // check runs once per language, not once per row every 700 ms.
        guard let target = await MainActor.run(body: { controller.translationTarget })
        else { return }
        let targetLanguage = Locale.Language(identifier: target)
        let availability = LanguageAvailability()
        var statusCache: [String: LanguageAvailability.Status] = [:]
        var didPrepare = false

        while !Task.isCancelled {
            let approved = await MainActor.run { controller.translationDownloadApproved }
            if approved && !didPrepare {
                guard await Self.prepare(box: box, controller: controller) else { continue }
                didPrepare = true
            }
            let pending = await Self.pendingRows(controller: controller)
            let partition = await Self.partition(
                pending, approved: approved, target: target, targetLanguage: targetLanguage,
                availability: availability, cache: statusCache)
            statusCache = partition.cache
            await MainActor.run {
                controller.translationNeedsDownload = partition.needsDownload && !approved
            }
            await Self.apply(partition.ready, box: box, controller: controller)
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    /// Downloads the language assets via Apple's deliberate, expected sheet.
    /// Returns false (and clears approval) if the user cancels, so the loop
    /// falls back to the gated banner instead of auto-presenting the sheet.
    nonisolated private static func prepare(
        box: SessionBox, controller: RecordingController
    ) async -> Bool {
        do {
            try await box.session.prepareTranslation()
            return true
        } catch {
            await MainActor.run { controller.translationDownloadApproved = false }
            try? await Task.sleep(for: .milliseconds(700))
            return false
        }
    }

    /// The closed, not-yet-translated caption rows. The newest row is still
    /// growing (the coalescer only ever extends the last one), so it's skipped.
    nonisolated private static func pendingRows(controller: RecordingController) async -> [Row] {
        await MainActor.run {
            let openID = controller.captions.last?.id
            return controller.captions.suffix(60)
                .filter {
                    $0.id != openID && controller.translations[$0.id] == nil && $0.text.count >= 4
                }
                .map { ($0.id, $0.text, $0.language) }
        }
    }

    /// Splits pending rows into ones whose language pair is installed (safe to
    /// translate now) and flags whether any pair still needs downloading.
    /// Skipping uninstalled pairs is what prevents Apple's sheet from popping
    /// up mid-meeting; once the user approves, every row is translated.
    nonisolated private static func partition(
        _ pending: [Row], approved: Bool, target: String, targetLanguage: Locale.Language,
        availability: LanguageAvailability, cache: [String: LanguageAvailability.Status]
    ) async -> (ready: [Ready], needsDownload: Bool, cache: [String: LanguageAvailability.Status]) {
        if approved { return (pending.map { ($0.id, $0.text) }, false, cache) }
        var cache = cache
        var ready: [Ready] = []
        var needsDownload = false
        for row in pending {
            let source = row.source ?? Self.likelySource(for: target)
            let status: LanguageAvailability.Status
            if let cached = cache[source] {
                status = cached
            } else {
                status =
                    (try? await availability.status(
                        from: Locale.Language(identifier: source), to: targetLanguage))
                    ?? .unsupported
                cache[source] = status
            }
            switch status {
            case .installed: ready.append((row.id, row.text))
            case .supported: needsDownload = true  // downloadable, not yet installed
            default: break  // unsupported pair — leave the row untranslated
            }
        }
        return (ready, needsDownload, cache)
    }

    /// Translates the ready rows and stores the results on the controller.
    nonisolated private static func apply(
        _ ready: [Ready], box: SessionBox, controller: RecordingController
    ) async {
        guard !ready.isEmpty else { return }
        let requests = ready.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
        }
        guard let responses = try? await box.session.translations(from: requests) else { return }
        let translated: [(UUID, String)] = responses.compactMap { response in
            guard
                let identifier = response.clientIdentifier,
                let id = UUID(uuidString: identifier)
            else { return nil }
            return (id, response.targetText)
        }
        await MainActor.run {
            for (id, text) in translated { controller.translations[id] = text }
        }
    }

    /// Best-guess source when a caption has no detected language: the
    /// opposite of the target for the two languages the picker offers, else
    /// the device language. Only used to check availability, never to force a
    /// translation of the wrong pair.
    nonisolated private static func likelySource(for target: String) -> String {
        switch target {
        case "es": return "en"
        case "en": return "es"
        default: return Locale.current.language.languageCode?.identifier ?? "en"
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
