import PortavozCore

/// Durable operation identity layered over D25's language-independent material
/// cache key. Output language and source revision are explicit job inputs.
public enum SummaryOperationFingerprint {
    private static let version = "summary-operation-v1"

    public static func compute(
        request: SummaryRequest,
        providerID: String,
        transcriptRevision: Int
    ) -> String {
        let material = SummaryFingerprint.compute(
            request: request, providerID: providerID)
        return OperationFingerprint.make(
            version: version,
            components: [
                material,
                request.targetLanguage,
                String(transcriptRevision)
            ])
    }
}
