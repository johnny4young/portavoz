import Foundation

/// The user's instruction for how Polish reshapes a dictation. It is plain text handed to the
/// summary engine with the dictation, never a Skill, code or a source of new facts.
public struct DictationRecipe: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameLength = 60
    public static let maximumInstructionLength = 500
    public static let maximumCustomRecipes = 20

    public let id: String
    public var name: String
    public var instruction: String

    public init(id: String, name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }

    public var isBuiltIn: Bool { id.hasPrefix(Self.builtInPrefix) }

    public var isValid: Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !name.isEmpty && name.count <= Self.maximumNameLength
            && !instruction.isEmpty && instruction.count <= Self.maximumInstructionLength
    }

    static let builtInPrefix = "builtin."

    /// Names are English catalog keys, shown localized; instructions go to the engine as written.
    public static let builtIns = [
        DictationRecipe(
            id: "builtin.formal", name: "Formal",
            instruction: "Make it formal and polite, as in a professional email. Keep about the same length."),
        DictationRecipe(
            id: "builtin.friendly", name: "Friendly",
            instruction: "Make it warm and friendly, as if writing to a colleague you know well."),
        DictationRecipe(
            id: "builtin.bullets", name: "Bullet list",
            instruction: "Turn it into a short bulleted list with one idea per bullet."),
        DictationRecipe(
            id: "builtin.concise", name: "Concise",
            instruction: "Make it as short and direct as possible without dropping any fact.")
    ]
}

/// What one dictation does after recognition: a mode and, for Polish, an optional recipe.
public struct DictationTextChoice: Codable, Equatable, Hashable, Sendable {
    public var mode: DictationTextMode
    /// Nil is the conservative copy edit; ignored unless the mode is Polish.
    public var recipeID: String?

    public init(mode: DictationTextMode, recipeID: String? = nil) {
        self.mode = mode
        self.recipeID = mode == .polish ? recipeID : nil
    }
}
