import Foundation
import Testing

@Suite(.exclusiveArgumentDomain)
struct ExclusiveArgumentDomainTests {
    private static let key = "exclusiveArgumentDomainProbe"

    @Test(arguments: ["literal", "clean", "polish", "translate", "rewrite", "dictate"])
    func eachTestOwnsAnEmptyArgumentDomain(value: String) async {
        let defaults = UserDefaults.standard
        #expect(defaults.volatileDomain(forName: UserDefaults.argumentDomain).isEmpty)
        defaults.setVolatileDomain([Self.key: value], forName: UserDefaults.argumentDomain)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(defaults.string(forKey: Self.key) == value)
    }
}
