import AppKit
import Foundation
import PortavozCore
import Testing

@testable import portavoz_app

/// Recognition is scripted, but every case enters the real session and final delivery.
// The existing controller harness overrides process-wide NSArgumentDomain.
// Serialize that fixture owner, not the production dictation implementation.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DictationTextModeDeliveryTests {
    struct Example: Sendable {
        let recognized: String
        let cleaned: String
        let withoutFillers: String
    }

    nonisolated static let examples = [
        Example(recognized: "um Don’t delete C++ 1,250.50 USD", cleaned: "Don’t delete Swift 1,250.50 USD",
                withoutFillers: "um Don’t delete Swift 1,250.50 USD"),
        Example(recognized: "eh No borres C++ 1.250,50 €", cleaned: "No borres Swift 1.250,50 €",
                withoutFillers: "eh No borres Swift 1.250,50 €"),
        Example(recognized: "uh don’t replace summer museum", cleaned: "don’t replace summer museum",
                withoutFillers: "uh don’t replace summer museum"),
        Example(recognized: "eh no cambies Café pues este", cleaned: "no cambies Café pues este",
                withoutFillers: "eh no cambies Café pues este")
    ]

    @Test(arguments: examples)
    func newPreferencesDeliverLiteralText(_ example: Example) async throws {
        let harness = DictationControllerHarness(text: example.recognized)
        defer { harness.controller.cancel() }
        let result = try await deliver(harness)
        #expect(result == example.recognized,
                "An untouched installation must not opt itself into deterministic cleaning")
    }

    @Test(arguments: examples)
    func firstEnableAfterAppCompositionStillDeliversLiteral(_ example: Example) async throws {
        let harness = DictationControllerHarness(text: example.recognized)
        defer { harness.controller.cancel() }
        let services = try AppServices(
            arguments: ["-use-temp-store"], environment: [:], defaults: harness.defaults,
            dictation: harness.controller)
        harness.set(true, forKey: DictationController.defaultsKey)
        let result = try await deliver(harness)
        #expect(result == example.recognized,
                "Enabling dictation for the first time must not masquerade as migrated legacy preferences")
        withExtendedLifetime(services) {}
    }

    @Test(arguments: examples)
    func existingDictationKeepsImplicitCleaning(_ example: Example) async throws {
        let harness = DictationControllerHarness(text: example.recognized)
        defer { harness.controller.cancel() }
        harness.set(false, forKey: DictationController.defaultsKey)
        harness.set(#"[{"trigger":"C++","replacement":"Swift"}]"#,
                    forKey: DictationController.replacementsKey)
        let result = try await deliver(harness)
        #expect(result == example.cleaned,
                "A saved disabled toggle is still prior configuration, not a fresh installation")
    }

    @Test(arguments: examples)
    func existingFillerChoiceAndDictionaryRemainIndependent(_ example: Example) async throws {
        let harness = DictationControllerHarness(text: example.recognized)
        defer { harness.controller.cancel() }
        harness.set(false, forKey: DictationController.fillerFilterKey)
        harness.set(#"[{"trigger":"C++","replacement":"Swift"}]"#,
                    forKey: DictationController.replacementsKey)
        let result = try await deliver(harness)
        #expect(result == example.withoutFillers)
    }

    struct Precedence: Sendable {
        let global: DictationTextMode
        let profile: DictationTextMode
        let session: DictationTextMode?
        let expected: DictationTextMode
    }

    nonisolated static let precedences = [
        Precedence(global: .clean, profile: .literal, session: nil, expected: .literal),
        Precedence(global: .literal, profile: .clean, session: nil, expected: .clean),
        Precedence(global: .literal, profile: .clean, session: .literal, expected: .literal),
        Precedence(global: .clean, profile: .literal, session: .clean, expected: .clean)
    ]

    @Test(arguments: precedences, examples)
    func modesReachDeliveryFromTheCapturedDestination(_ choice: Precedence, _ example: Example) async throws {
        let harness = DictationControllerHarness(text: example.recognized)
        defer { harness.controller.cancel() }
        harness.set(choice.global.rawValue, forKey: DictationTextPreferences.modeKey)
        harness.set("[{\"bundleIdentifier\":\"app.portavoz.example\",\"mode\":\"\(choice.profile.rawValue)\"}]",
                    forKey: DictationTextPreferences.profilesKey)
        harness.set(#"[{"trigger":"C++","replacement":"Swift"}]"#, forKey: DictationController.replacementsKey)
        var dependencies = harness.dependencies
        let capture = dependencies.captureDestination
        var captures = 0
        dependencies.captureDestination = {
            captures += 1
            var target = capture()
            target.bundleIdentifier = "app.portavoz.example"
            return target
        }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        if let session = choice.session { harness.controller.selectTextMode(session) }
        #expect(harness.controller.textMode == choice.expected)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.finishes == 1 && harness.insertions.count == 1 }
        #expect(harness.insertions == [choice.expected == .literal ? example.recognized : example.cleaned])
        #expect(captures == 1, "Profile resolution must not recapture focus or delivery authority")
        #expect(harness.defaults.string(forKey: DictationTextPreferences.modeKey) == choice.global.rawValue)
    }

    @Test(arguments: examples)
    func stopFreezesChoiceAndRestartDoesNotKeepAnOverride(_ example: Example) async throws {
        let harness = DictationControllerHarness(text: example.recognized)
        defer { harness.controller.cancel() }
        harness.set("literal", forKey: DictationTextPreferences.modeKey)
        harness.set(#"[{"trigger":"C++","replacement":"Swift"}]"#, forKey: DictationController.replacementsKey)
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.controller.selectTextMode(.clean)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        #expect(harness.controller.canChangeTextMode == false)
        harness.controller.selectTextMode(.literal)
        try await eventually { harness.finishes == 1 && harness.insertions.count == 1 }
        #expect(harness.insertions == [example.cleaned])
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.loads == 2 && harness.controller.partialText == harness.text }
        #expect(harness.controller.textMode == .literal)
        #expect(harness.defaults.string(forKey: DictationTextPreferences.modeKey) == "literal")
    }

    @Test
    func settingsEditsCannotChangeTheAdmittedSessionSnapshot() async throws {
        let harness = DictationControllerHarness(text: "um don’t delete C++ 1,250.50")
        defer { harness.controller.cancel() }
        harness.set("clean", forKey: DictationTextPreferences.modeKey)
        harness.set(#"[{"trigger":"C++","replacement":"Swift"}]"#, forKey: DictationController.replacementsKey)
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.set(false, forKey: DictationController.fillerFilterKey)
        harness.set("literal", forKey: DictationTextPreferences.modeKey)
        harness.set(#"[{"trigger":"C++","replacement":"Rust"}]"#, forKey: DictationController.replacementsKey)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.finishes == 1 && harness.insertions.count == 1 }
        #expect(harness.insertions == ["don’t delete Swift 1,250.50"])
    }

    @Test(arguments: [
        "not json", "{}", "[{}]",
        #"[{"bundleIdentifier":"app.portavoz.example","mode":"translate"}]"#,
        #"[{"bundleIdentifier":"app.portavoz.example","mode":"clean"},{"bundleIdentifier":"app.portavoz.example","mode":"literal"}]"#
    ])
    func corruptProfilesStayRecoverableWithoutOverridingGlobalMode(_ json: String) async throws {
        let harness = DictationControllerHarness(text: "eh No borres estas notas 1.250,50 €")
        defer { harness.controller.cancel() }
        harness.set("literal", forKey: DictationTextPreferences.modeKey)
        harness.set(json, forKey: DictationTextPreferences.profilesKey)
        let model = DictationTextSettingsModel(defaults: harness.defaults, temporary: true)
        #expect(model.hasInvalidProfiles)
        #expect(harness.defaults.string(forKey: DictationTextPreferences.profilesKey) == json)
        #expect(try await deliver(harness) == harness.text)
        model.resetProfiles()
        #expect(model.hasInvalidProfiles == false && model.profiles.isEmpty)
        #expect(harness.defaults.string(forKey: DictationTextPreferences.profilesKey) == "[]")
    }

    private func deliver(_ harness: DictationControllerHarness) async throws -> String {
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.finishes == 1 && harness.insertions.count == 1 }
        return try #require(harness.insertions.first)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "The real controller must reach the asserted lifecycle boundary")
    }
}

extension DictationTextModeDeliveryTests {
    @Test(arguments: [nil, "app.portavoz", "app.portavoz.example.extra", "APP.portavoz.example"] as [String?])
    func aDifferentDestinationDoesNotBorrowTheApplicationProfile(_ identifier: String?) async throws {
        let harness = DictationControllerHarness(text: "um no borres C++ 9,50 €")
        defer { harness.controller.cancel() }
        harness.set("literal", forKey: DictationTextPreferences.modeKey)
        harness.set(#"[{"bundleIdentifier":"app.portavoz.example","mode":"clean"}]"#,
                    forKey: DictationTextPreferences.profilesKey)
        var dependencies = harness.dependencies
        let capture = dependencies.captureDestination
        dependencies.captureDestination = {
            var target = capture()
            target.bundleIdentifier = identifier
            return target
        }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        #expect(harness.controller.textMode == .literal)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.insertions.count == 1 }
        #expect(harness.insertions == [harness.text])
    }

    @Test
    func cancelDiscardsTheSessionOverrideWithoutDeliveringAnything() async throws {
        let harness = DictationControllerHarness(text: "eh no cambies Café")
        defer { harness.controller.cancel() }
        harness.set("literal", forKey: DictationTextPreferences.modeKey)
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.controller.selectTextMode(.clean)
        harness.controller.cancel()
        #expect(harness.insertions.isEmpty)
        #expect(harness.controller.canChangeTextMode == false)
        harness.controller.selectTextMode(.clean)
        // Production constructs a distinct source per session; an old cancellation
        // must not close a test double reused as the next session's microphone.
        let nextMicrophone = ControlledDictationMicrophone()
        var dependencies = harness.dependencies
        dependencies.makeMicrophone = { .init(source: nextMicrophone, warmUp: {}) }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.loads == 2 && harness.controller.partialText == harness.text }
        #expect(harness.controller.textMode == .literal)
        #expect(harness.defaults.string(forKey: DictationTextPreferences.modeKey) == "literal")
    }

    @Test
    func settingsMutationsStayBoundedAndTemporary() throws {
        let suite = "dictation-text-temporary-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        #expect(defaults.persistentDomain(forName: suite) == nil)
        let model = DictationTextSettingsModel(defaults: defaults, temporary: true)
        model.setGlobalMode(.clean)
        for index in 0..<DictationTextPreferences.maximumProfiles {
            model.setProfile(bundleIdentifier: "app.portavoz.fixture\(index)", mode: .literal)
        }
        let original = defaults.string(forKey: DictationTextPreferences.profilesKey)
        model.setProfile(bundleIdentifier: "app.portavoz.extra", mode: .clean)
        #expect(model.selectionError == .invalidApplication)
        #expect(model.profiles.count == 64)
        #expect(defaults.string(forKey: DictationTextPreferences.profilesKey) == original)
        model.setProfile(bundleIdentifier: "app.portavoz.fixture0", mode: .clean)
        #expect(model.selectionError == nil)
        #expect(model.profiles.count == 64)
        #expect(model.profiles.first { $0.bundleIdentifier == "app.portavoz.fixture0" }?.mode == .clean)
        let replaced = defaults.string(forKey: DictationTextPreferences.profilesKey)
        model.setProfile(bundleIdentifier: "/Applications/Private name.app", mode: .literal)
        #expect(model.selectionError == .invalidApplication)
        #expect(defaults.string(forKey: DictationTextPreferences.profilesKey) == replaced)
        #expect(model.beginApplicationSelection())
        #expect(model.beginApplicationSelection() == false)
        model.finishApplicationSelection()
        #expect(model.beginApplicationSelection())
        model.finishApplicationSelection()
        model.removeProfile(bundleIdentifier: "app.portavoz.fixture0")
        #expect(model.profiles.count == 63)
        #expect(defaults.persistentDomain(forName: suite) == nil)
    }

    @Test
    func fillerAndReplacementControlsFollowAnyCleanUse() throws {
        let suite = "dictation-text-clean-use-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        let model = DictationTextSettingsModel(defaults: defaults, temporary: true)
        #expect(model.globalMode == .literal)
        #expect(model.cleanModeInUse == false, "Literal never applies fillers or replacements")
        model.setProfile(bundleIdentifier: "app.portavoz.fixture", mode: .clean)
        #expect(model.cleanModeInUse, "One Clean application profile still uses them")
        model.removeProfile(bundleIdentifier: "app.portavoz.fixture")
        #expect(model.cleanModeInUse == false)
        model.setGlobalMode(.clean)
        #expect(model.cleanModeInUse)
    }

    @Test
    func profileCodecAcceptsItsExactLimitsAndRejectsTheNextByte() throws {
        let maximumIdentifier = String(repeating: "a", count: 255)
        let profiles = (0..<64).map {
            DictationApplicationTextProfile(bundleIdentifier: "\($0)." + String(repeating: "a", count: 250), mode: .literal)
        }
        #expect(DictationTextPreferences.isValidBundleIdentifier(maximumIdentifier))
        #expect(DictationTextPreferences.isValidBundleIdentifier(maximumIdentifier + "a") == false)
        let encoded = try DictationTextPreferences.encodeProfiles(profiles)
        #expect(try DictationTextPreferences.decodeProfiles(encoded).count == 64)
        let padded = encoded + String(repeating: " ", count: DictationTextPreferences.maximumProfileBytes - encoded.utf8.count)
        #expect(try DictationTextPreferences.decodeProfiles(padded).count == 64)
        #expect(throws: DictationTextPreferences.ProfileFailure.self) {
            try DictationTextPreferences.decodeProfiles(padded + " ")
        }
        #expect(throws: DictationTextPreferences.ProfileFailure.self) {
            try DictationTextPreferences.encodeProfiles(profiles + [.init(bundleIdentifier: "app.extra", mode: .clean)])
        }
    }

    @Test(arguments: ["", "Café", "app/private", "app name", "app\nname", "https://example.com"])
    func rejectedIdentifiersCannotReplaceTheSavedProfile(_ identifier: String) {
        let harness = DictationControllerHarness(text: "unused")
        let model = DictationTextSettingsModel(defaults: harness.defaults, temporary: true)
        model.setProfile(bundleIdentifier: "app.portavoz.valid", mode: .literal)
        let original = harness.defaults.string(forKey: DictationTextPreferences.profilesKey)
        model.setProfile(bundleIdentifier: identifier, mode: .clean)
        #expect(model.selectionError == .invalidApplication)
        #expect(model.profiles.count == 1)
        #expect(harness.defaults.string(forKey: DictationTextPreferences.profilesKey) == original)
    }

    @Test
    func chooserFixtureRequiresAllIsolationConditions() {
        let flags = ["-use-temp-store", "-seed-dictation-profile-picker"]
        let root = ["TMPDIR": "/private/tmp/owned-fixture"]
        #expect(DictationProfilePickerUITestFixture.directory(
            arguments: flags, environment: root, usesTemporaryStore: true)?.path
            == "/private/tmp/owned-fixture/dictation-profile-applications")
        #expect(DictationProfilePickerUITestFixture.directory(
            arguments: flags, environment: root, usesTemporaryStore: false) == nil)
        for arguments in [[], [flags[0]], [flags[1]]] {
            #expect(DictationProfilePickerUITestFixture.directory(
                arguments: arguments, environment: root, usesTemporaryStore: true) == nil)
        }
        for environment in [[:], ["TMPDIR": "relative"], ["TMPDIR": ""]] {
            #expect(DictationProfilePickerUITestFixture.directory(
                arguments: flags, environment: environment, usesTemporaryStore: true) == nil)
        }
    }
}

extension DictationTextModeDeliveryTests {
    @Test(arguments: [DictationDeliveryOutcome.Refusal.secureField, .focusUnavailable], examples)
    func unavailableDeliveryKeepsTheCapturedApplicationPolicy(
        _ failure: DictationDeliveryOutcome.Refusal, _ example: Example
    ) async throws {
        let harness = DictationControllerHarness(text: example.recognized)
        defer { harness.controller.cancel() }
        harness.set("clean", forKey: DictationTextPreferences.modeKey)
        harness.set(#"[{"bundleIdentifier":"app.portavoz.example","mode":"literal"}]"#,
                    forKey: DictationTextPreferences.profilesKey)
        harness.set(#"[{"trigger":"C++","replacement":"Swift"}]"#, forKey: DictationController.replacementsKey)
        var dependencies = harness.dependencies
        dependencies.captureDestination = {
            .unavailable(name: "Not an identity", bundleIdentifier: "app.portavoz.example", result: failure)
        }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        #expect(harness.controller.textMode == .literal)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.phase == .recovery(failure) }
        #expect(harness.controller.recoveryText == example.recognized)
        #expect(harness.controller.canRetryDelivery == false)
        harness.controller.retryUndeliveredText()
        #expect(harness.insertions.isEmpty, "A profile never grants delivery or retry authority")
        #expect(harness.controller.phase == .recovery(failure))
    }

    @Test
    func chooserWithoutAnOwnedWindowReportsFailureAndRetiresSelection() async throws {
        _ = NSApplication.shared
        try #require(NSApp.keyWindow == nil, "The isolated unit host must not own a visible chooser window")
        let harness = DictationControllerHarness(text: "unused")
        let services = try AppServices(
            arguments: ["-use-temp-store"], environment: [:], defaults: harness.defaults,
            dictation: harness.controller)
        await services.selectDictationProfileApplication()
        #expect(services.dictationTextSettings.selectionError == .unavailableWindow)
        #expect(services.dictationTextSettings.isSelectingApplication == false)
        #expect(services.dictationTextSettings.profiles.isEmpty)
        #expect(harness.defaults.string(forKey: DictationTextPreferences.profilesKey) == nil)
    }

    @Test
    func failedDatabaseAdmissionDoesNotInitializeTextPreferences() {
        let harness = DictationControllerHarness(text: "unused")
        #expect(harness.defaults.object(forKey: DictationTextPreferences.modeKey) == nil)
        #expect(throws: (any Error).self) {
            _ = try AppServices(
                arguments: ["-use-temp-store", "-simulate-database-open-failure"],
                environment: [:], defaults: harness.defaults, dictation: harness.controller)
        }
        #expect(harness.defaults.object(forKey: DictationTextPreferences.modeKey) == nil)
    }
}

extension DictationTextModeDeliveryTests {
    @Test(arguments: [DictationTextMode.literal, .clean], ["", " \n\t ", "...", "um eh"])
    func emptyResultsNeverPasteButLiteralFillersRemainWords(_ mode: DictationTextMode, _ recognized: String) async throws {
        let harness = DictationControllerHarness(text: recognized)
        defer { harness.controller.cancel() }
        harness.set(mode.rawValue, forKey: DictationTextPreferences.modeKey)
        harness.controller.toggle(using: harness.dependencies)
        // An empty partial cannot witness recognition readiness: it is also the
        // initial UI value. Reach the recognizer and the actual first buffer.
        try await eventually { harness.hints != nil && harness.controller.phase == .listening }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.finishes == 1 }
        if mode == .literal && recognized == "um eh" {
            #expect(harness.insertions == [recognized])
        } else {
            #expect(harness.insertions.isEmpty)
            #expect(harness.controller.phase == .idle)
            #expect(harness.measurements.map(\.outcome) == [.empty])
        }
    }
}
