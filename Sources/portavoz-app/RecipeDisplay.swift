import PortavozCore

/// Localized presentation of summary structures. Built-in template names
/// and section titles are catalog keys (the product is Spanish-first, but
/// recipe identity stays English in storage and prompts); user-authored
/// custom structures render verbatim — their text belongs to the user.
extension Recipe {
    var localizedDisplayName: String {
        Self.isCustom(id) ? displayName : L10n.text(displayName)
    }

    /// The " · "-joined section list shown under a template in pickers, so
    /// the user sees what a structure produces BEFORE generating with it.
    var localizedSectionSummary: String {
        let titles = Self.isCustom(id) ? sections : sections.map { L10n.text($0) }
        return titles.joined(separator: " · ")
    }
}
