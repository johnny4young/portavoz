import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
extension GenerationOptions {
    /// Deterministic decoding for every Portavoz prompt.
    ///
    /// Xcode 27 renamed the `sampling:` initializer to `samplingMode:` and
    /// deprecates the old label, which the warnings-as-errors build rejects.
    /// Xcode 26 ships only the old label. Keeping the choice in one place lets
    /// both toolchains compile the same source without a warning.
    static func greedy(maximumResponseTokens: Int? = nil) -> GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
        #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
        #endif
    }
}
