/// An optional model the user downloads only from an explicit Settings choice.
enum ConsentedModelState: Equatable {
    case unknown
    case missing
    case downloading(Int)
    case ready
    case failed
}
