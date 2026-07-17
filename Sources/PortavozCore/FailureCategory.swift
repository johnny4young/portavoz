import Foundation

/// Product-level severity for a failure, independent of localized copy or a
/// concrete workflow. The category determines the minimum recovery contract;
/// workflow-specific enums retain the stable code and exact context.
public enum FailureCategory: String, Codable, Equatable, Hashable, Sendable {
    case critical
    case recoverable
    case degradable
    case external
    case destructive
}

/// A failure safe to move across application boundaries. Presentation owns
/// localization; support evidence may retain only the stable code/category.
public protocol CodedFailure: Error, Sendable {
    var code: String { get }
    var category: FailureCategory { get }
}
