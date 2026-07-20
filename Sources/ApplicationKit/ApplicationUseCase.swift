import PortavozCore

/// A single application workflow with explicit Sendable input and output.
///
/// Concrete use cases own orchestration across capability Kits. Presentation
/// models call this boundary but never receive SQL records, model-specific
/// objects, windows, or localized copy from it.
public protocol ApplicationUseCase<Request, Response>: Sendable {
    associatedtype Request: Sendable
    associatedtype Response: Sendable

    func execute(_ request: Request) async throws -> Response
}

extension ApplicationUseCase {
    public func callAsFunction(_ request: Request) async throws -> Response {
        try await execute(request)
    }
}
