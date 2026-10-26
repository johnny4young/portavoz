/// What the two-line strip shows: the newest words, since those are the ones
/// being spoken. Earlier words are elided from the front at a word boundary.
enum DictationPanelTranscript {
    /// Roughly two body-font lines of the 520-pt strip, with room for wide glyphs.
    static let visibleCharacters = 120

    struct Visible: Equatable {
        var confirmed: String
        /// Includes its leading separator, styled with the volatile tail.
        var partial: String
    }

    static func visible(confirmed: String, partial: String, limit: Int = visibleCharacters) -> Visible {
        let joined = partial.isEmpty ? "" : " " + partial
        let full = confirmed + joined
        guard limit > 0, full.count > limit else { return Visible(confirmed: confirmed, partial: joined) }
        var start = full.index(full.endIndex, offsetBy: -limit)
        if let space = full[start...].firstIndex(where: \.isWhitespace),
           full.distance(from: space, to: full.endIndex) > limit / 2 {
            start = full.index(after: space)
        }
        let boundary = full.index(full.startIndex, offsetBy: confirmed.count)
        guard start < boundary else { return Visible(confirmed: "…", partial: String(full[start...])) }
        return Visible(confirmed: "…" + full[start..<boundary], partial: String(full[boundary...]))
    }
}
