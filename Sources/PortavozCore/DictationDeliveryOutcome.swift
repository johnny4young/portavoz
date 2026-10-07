/// Delivery is independent of recognition and storage. A posted event cannot
/// be safely retried merely because the external editor cannot acknowledge it.
public enum DictationDeliveryOutcome: Sendable, Equatable {
    /// The expected inserted span and caret were observed in the captured field.
    /// This is a point-in-time observation, not an atomic editor transaction.
    case verified
    case dispatched
    case refused(Refusal)

    public enum Refusal: Sendable, Equatable {
        case emptyText
        case secureField
        case focusUnavailable
        case targetChanged
        case modifiersStillPressed
        case clipboardUnavailable
        case eventUnavailable
        case cancelled
    }
}
