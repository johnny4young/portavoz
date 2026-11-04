import Foundation
import ModelStoreKit
import Testing

@testable import portavoz_app

@MainActor
struct ModelsOnThisMacSectionTests {
    @Test func aListOfAppsFollowsTheLanguageItIsAskedFor() {
        let model = ModelStore.InstalledModel(
            id: "model", name: "Model", bytes: nil, isUsedHere: false, otherApps: ["Uno", "Dos"])

        let spanish = ModelsOnThisMacSection.detail(of: model, locale: Locale(identifier: "es"))
        let english = ModelsOnThisMacSection.detail(of: model, locale: Locale(identifier: "en"))

        #expect(spanish.contains("Uno y Dos"))
        #expect(english.contains("Uno and Dos"))
    }
}
