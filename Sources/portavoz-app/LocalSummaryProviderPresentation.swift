import ApplicationKit

extension LocalSummaryProviderRecommendation {
    var localizedHeadline: String {
        switch headline {
        case .appleOnDevice:
            L10n.text("Apple Intelligence: on-device summaries, free and fast.")
        case .ollama:
            L10n.text("Local Ollama: summaries 100% on your Mac, without Apple Intelligence.")
        case .builtIn:
            L10n.text("Built-in local model: summaries without installing anything.")
        case .unavailable:
            L10n.text("No local summary engine.")
        }
    }

    var localizedReasons: [String] {
        reasons.map { reason in
            switch reason {
            case .appleOnDeviceAvailable:
                // One localization key; splitting it would create false catalog fragments.
                L10n.text(
                    // swiftlint:disable:next line_length
                    "Your Mac has Apple Intelligence — the summary runs on the Neural Engine without downloading anything.")
            case .ollamaAvailable:
                L10n.text(
                    "Apple Intelligence is unavailable, but Ollama is running — local summaries with no cloud.")
            case .ollamaHasNoEligibleModel:
                L10n.text("Ollama is running, but it has no chat-capable model.")
            case .builtInEligible:
                L10n.text(
                    "Your Mac can run the built-in model after one verified 3 GB download, entirely on-device.")
            case .noCompatibleLocalProvider:
                // One localization key; splitting it would create false catalog fragments.
                L10n.text(
                    // swiftlint:disable:next line_length
                    "No compatible local summary provider is ready. Install an Ollama chat model or free enough memory and disk for the built-in model.")
            case .lowMemoryForOllama(let memoryGB):
                L10n.format(
                    "With %d GB of RAM, prefer Ollama models up to 8B to keep Portavoz responsive.",
                    memoryGB)
            case .lowDisk(let freeDiskGB):
                L10n.format(
                    "Only %d GB of free disk remains; use Compact Whisper to save about 1 GB.",
                    freeDiskGB)
            }
        }
    }
}

extension LocalSummaryProviderDiscovery {
    var localizedOllamaStatus: String {
        switch profile.ollama {
        case .unavailable:
            L10n.text(
                "Ollama is not responding on localhost:11434. Install it and run “ollama serve”.")
        case .running(let models) where models.isEmpty:
            L10n.text(
                "Ollama is running but has no models. Download one with “ollama pull llama3.2”.")
        case .running(let models):
            L10n.format("%d model(s) available.", models.count)
        }
    }
}
