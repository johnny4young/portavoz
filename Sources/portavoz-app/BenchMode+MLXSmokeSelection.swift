import ModelStoreKit

extension BenchMode {
    enum MLXSmokeSelectionError: Error, Equatable {
        case conflictingModels
    }

    static func mlxSmokeDescriptor(
        arguments: [String]
    ) throws -> ModelDescriptor {
        let selections: [(String, ModelDescriptor)] = [
            ("qwen3", ModelCatalog.mlxQwen3),
            ("qwen35-0.8b", ModelCatalog.mlxQwen35Point8BChallenger),
            ("qwen35-2b", ModelCatalog.mlxQwen35TwoBChallenger),
            ("qwen35-4b", ModelCatalog.mlxQwen35)
        ]
        let requested = selections.filter { arguments.contains($0.0) }
        guard requested.count <= 1 else {
            throw MLXSmokeSelectionError.conflictingModels
        }
        return requested.first?.1 ?? ModelCatalog.mlxQwen35
    }
}
