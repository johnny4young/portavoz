import Foundation
import Testing

/// The argument domain is one per process, whatever `UserDefaults` suite
/// writes it, so parallel suites that use it would overwrite each other's
/// settings. Tests carrying this trait run one at a time on an empty domain.
struct ExclusiveArgumentDomain: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        await ArgumentDomainGate.shared.acquire()
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        do {
            try await function()
        } catch {
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
            await ArgumentDomainGate.shared.release()
            throw error
        }
        defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        await ArgumentDomainGate.shared.release()
    }
}

extension Trait where Self == ExclusiveArgumentDomain {
    static var exclusiveArgumentDomain: Self { Self() }
}

private actor ArgumentDomainGate {
    static let shared = ArgumentDomainGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
