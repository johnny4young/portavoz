import Foundation
import PortavozCore

enum LiveAssistTranslationReliability {
    static func assetActionReceipt(
        readiness: LiveTranslationAssetReadiness
    ) -> String {
        switch LiveTranslationAssetPolicy.action(
            readiness: readiness,
            downloadApproved: false,
            preparedInThisLane: false) {
        case .translate:
            "translate"
        case .requestDownloadConsent:
            "requestDownloadConsent"
        case .prepareAssets:
            "prepareAssets"
        case .passthroughUnsupported:
            "passthroughUnsupported"
        }
    }

    static func invalidPublicationCount(
        rows: [TranscriptSegment],
        pair: LiveTranslationPair?,
        pendingIDs: [UUID]
    ) -> Int {
        guard let pair,
              let id = pendingIDs.first,
              let source = rows.first(where: { $0.id == id })
        else { return 0 }
        var revised = source
        revised.text += " revised"
        let values = [id: "translated"]
        let sourceTexts = [id: source.text]
        let stale = LiveTranslationResultAdmission.admit(
            values: values,
            sourceTexts: sourceTexts,
            currentSegments: [revised],
            pair: pair)
        let duplicate = LiveTranslationResultAdmission.admit(
            values: values,
            sourceTexts: sourceTexts,
            currentSegments: [source, source],
            pair: pair)
        return stale.values.count + duplicate.values.count
    }
}
