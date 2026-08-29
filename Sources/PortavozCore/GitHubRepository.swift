import Foundation

/// One canonical GitHub repository destination. The deliberately narrow ASCII
/// grammar prevents path, query, fragment, and percent-encoding ambiguity at
/// egress boundaries while covering GitHub's ordinary owner/repository form.
public struct GitHubRepository: Equatable, Hashable, Sendable {
    public static let maximumOwnerLength = 39
    public static let maximumNameLength = 100

    public let owner: String
    public let name: String

    public var rawValue: String { "\(owner)/\(name)" }

    public init?(_ input: String) {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(
            separator: "/",
            omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let owner = String(components[0])
        let name = String(components[1])
        guard Self.isValidOwner(owner), Self.isValidName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    private static func isValidOwner(_ value: String) -> Bool {
        guard (1...maximumOwnerLength).contains(value.count),
              value.first?.isASCIIAlphaNumeric == true,
              value.last?.isASCIIAlphaNumeric == true
        else { return false }
        return value.allSatisfy { $0.isASCIIAlphaNumeric || $0 == "-" }
    }

    private static func isValidName(_ value: String) -> Bool {
        guard (1...maximumNameLength).contains(value.count),
              value != ".", value != ".."
        else { return false }
        return value.allSatisfy {
            $0.isASCIIAlphaNumeric || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...90).contains($0.value)
                || (97...122).contains($0.value)
        }
    }
}
