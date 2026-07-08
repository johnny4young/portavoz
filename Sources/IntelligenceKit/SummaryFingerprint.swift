import CryptoKit
import Foundation
import PortavozCore

/// Identity of a summary's MATERIAL and method (D25 — Meetily's cache
/// pattern): transcript + user notes + glossary + recipe + provider +
/// prompt version, deliberately EXCLUDING the output language. Same
/// fingerprint + same language stored → regenerating is free (greedy
/// decoding makes the model repeat itself anyway). Same fingerprint in
/// another language → that snapshot is a translation pivot: translating
/// ~2k chars of summary costs a fraction of re-summarizing the transcript.
public enum SummaryFingerprint {
    /// Bump when PromptFactory changes enough that a cached summary no
    /// longer represents what a fresh run would produce.
    static let promptVersion = "p1"

    public static func compute(request: SummaryRequest, providerID: String) -> String {
        // The formatted transcript carries speaker names on purpose:
        // renaming S1 → José changes the attributions a faithful summary
        // must make, so it must invalidate the cache.
        let transcript = TranscriptFormatter.format(
            segments: request.segments, speakers: request.speakers)
        let notes = PromptFactory.notesBlock(request.contextItems)
        let canonical = [
            promptVersion,
            providerID,
            request.recipe.id,
            request.glossary.joined(separator: ","),
            notes,
            transcript
        ].joined(separator: "\u{1F}")  // unit separator: fields can't bleed
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
