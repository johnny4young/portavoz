import AppIntents
import CoreSpotlight
import Foundation

/// Native App Intents let Shortcuts, Spotlight, and Siri drive Portavoz
/// without the URL-scheme detour. `portavoz://record` remains supported as a
/// separate adapter for external automation tools.
struct StartRecordingIntent: AppIntent {
    // Reuses the app's existing catalog key so Shortcuts shows the same
    // localized label as the in-app record control on every locale.
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription(
        "Starts a new Portavoz meeting recording.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor
    func perform() async throws -> some IntentResult {
        // The foreground execution mode selects the exact bundle that owns
        // this intent. Route inside that process instead of asking
        // LaunchServices to choose among every installed URL handler.
        PortavozAppIntentBridge.requestStartRecording()
        return .result()
    }
}

/// Stops only the process-owned recording that is already active.
///
/// `perform()` reports that Portavoz accepted the request; it never claims
/// that capture was durably finalized before the recording controller finishes
/// its existing stop workflow. Every non-actionable state names one recovery.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let description = IntentDescription(
        "Stops the current Portavoz meeting recording.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let disposition = PortavozAppIntentBridge.requestStopRecording()
        return .result(dialog: IntentDialog(disposition.dialog))
    }
}

// MARK: - Local library entities

/// SDK-only dependency contract. Application composition installs the real
/// bounded catalog after the authoritative database opens; metadata extraction
/// keeps compiling this file without any project module.
protocol PortavozAppEntityCatalog: Sendable {
    func meetings(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozMeetingEntity]

    func people(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozPersonEntity]

    func commitments(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozCommitmentEntity]
}

private enum PortavozAppEntityCatalogUnavailable: LocalizedError {
    case libraryUnavailable

    var errorDescription: String? {
        "Portavoz could not read the library. Open Portavoz and use the recovery action shown."
    }
}

private struct UnavailablePortavozAppEntityCatalog: PortavozAppEntityCatalog {
    func meetings(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozMeetingEntity] {
        _ = (identifiers, matching, limit)
        throw PortavozAppEntityCatalogUnavailable.libraryUnavailable
    }

    func people(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozPersonEntity] {
        _ = (identifiers, matching, limit)
        throw PortavozAppEntityCatalogUnavailable.libraryUnavailable
    }

    func commitments(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozCommitmentEntity] {
        _ = (identifiers, matching, limit)
        throw PortavozAppEntityCatalogUnavailable.libraryUnavailable
    }
}

private enum PortavozAppEntityQueryPolicy {
    static let suggestionLimit = 20
    static let resolutionLimit = 50
    static let maximumQueryCharacterCount = 120

    static func boundedIdentifiers(_ values: [String]) -> [String] {
        Array(values.prefix(resolutionLimit))
    }

    static func boundedQuery(_ value: String) -> String {
        String(value.prefix(maximumQueryCharacterCount))
    }
}

struct PortavozMeetingEntity: AppEntity, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meeting"
    static let defaultQuery = PortavozMeetingEntityQuery()

    let id: String
    let title: String
    let dateDescription: String
    let startedAt: Date?
    let searchableContent: String?

    init(
        id: String,
        title: String,
        dateDescription: String,
        startedAt: Date? = nil,
        searchableContent: String? = nil
    ) {
        self.id = id
        self.title = title
        self.dateDescription = dateDescription
        self.startedAt = startedAt
        self.searchableContent = searchableContent
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(dateDescription)",
            image: .init(systemName: "person.2"))
    }
}

extension PortavozMeetingEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentCreationDate = startedAt
        attributes.contentDescription = searchableContent
        return attributes
    }
}

struct PortavozMeetingEntityQuery: EntityStringQuery {
    @AppDependency(default: UnavailablePortavozAppEntityCatalog())
    private var catalog: any PortavozAppEntityCatalog

    init() {}

    func entities(for identifiers: [String]) async throws -> [PortavozMeetingEntity] {
        try await catalog.meetings(
            identifiers: PortavozAppEntityQueryPolicy.boundedIdentifiers(identifiers),
            matching: nil,
            limit: PortavozAppEntityQueryPolicy.resolutionLimit)
    }

    func suggestedEntities() async throws -> [PortavozMeetingEntity] {
        try await catalog.meetings(
            identifiers: nil,
            matching: nil,
            limit: PortavozAppEntityQueryPolicy.suggestionLimit)
    }

    func entities(matching string: String) async throws -> [PortavozMeetingEntity] {
        try await catalog.meetings(
            identifiers: nil,
            matching: PortavozAppEntityQueryPolicy.boundedQuery(string),
            limit: PortavozAppEntityQueryPolicy.suggestionLimit)
    }
}

struct PortavozPersonEntity: AppEntity, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static let defaultQuery = PortavozPersonEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: .init(systemName: "person.crop.circle"))
    }
}

extension PortavozPersonEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        return attributes
    }
}

struct PortavozPersonEntityQuery: EntityStringQuery {
    @AppDependency(default: UnavailablePortavozAppEntityCatalog())
    private var catalog: any PortavozAppEntityCatalog

    init() {}

    func entities(for identifiers: [String]) async throws -> [PortavozPersonEntity] {
        try await catalog.people(
            identifiers: PortavozAppEntityQueryPolicy.boundedIdentifiers(identifiers),
            matching: nil,
            limit: PortavozAppEntityQueryPolicy.resolutionLimit)
    }

    func suggestedEntities() async throws -> [PortavozPersonEntity] {
        try await catalog.people(
            identifiers: nil,
            matching: nil,
            limit: PortavozAppEntityQueryPolicy.suggestionLimit)
    }

    func entities(matching string: String) async throws -> [PortavozPersonEntity] {
        try await catalog.people(
            identifiers: nil,
            matching: PortavozAppEntityQueryPolicy.boundedQuery(string),
            limit: PortavozAppEntityQueryPolicy.suggestionLimit)
    }
}

struct PortavozCommitmentEntity: AppEntity, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Confirmed commitment"
    static let defaultQuery = PortavozCommitmentEntityQuery()

    let id: String
    let title: String
    let dueDescription: String?
    let dueAt: Date?

    init(
        id: String,
        title: String,
        dueDescription: String?,
        dueAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.dueDescription = dueDescription
        self.dueAt = dueAt
    }

    var displayRepresentation: DisplayRepresentation {
        if let dueDescription {
            DisplayRepresentation(
                title: "\(title)",
                subtitle: "\(dueDescription)",
                image: .init(systemName: "checkmark.circle"))
        } else {
            DisplayRepresentation(
                title: "\(title)",
                image: .init(systemName: "checkmark.circle"))
        }
    }
}

extension PortavozCommitmentEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.dueDate = dueAt
        attributes.contentDescription = dueDescription
        return attributes
    }
}

struct PortavozCommitmentEntityQuery: EntityStringQuery {
    @AppDependency(default: UnavailablePortavozAppEntityCatalog())
    private var catalog: any PortavozAppEntityCatalog

    init() {}

    func entities(for identifiers: [String]) async throws -> [PortavozCommitmentEntity] {
        try await catalog.commitments(
            identifiers: PortavozAppEntityQueryPolicy.boundedIdentifiers(identifiers),
            matching: nil,
            limit: PortavozAppEntityQueryPolicy.resolutionLimit)
    }

    func suggestedEntities() async throws -> [PortavozCommitmentEntity] {
        try await catalog.commitments(
            identifiers: nil,
            matching: nil,
            limit: PortavozAppEntityQueryPolicy.suggestionLimit)
    }

    func entities(matching string: String) async throws -> [PortavozCommitmentEntity] {
        try await catalog.commitments(
            identifiers: nil,
            matching: PortavozAppEntityQueryPolicy.boundedQuery(string),
            limit: PortavozAppEntityQueryPolicy.suggestionLimit)
    }
}

/// Revalidates the entity snapshot and publishes the same process-local route
/// for both the system-owned App Intent flow and disposable real-app UI gates.
///
/// App Intents initializes `@AppDependency` only while it owns `perform()`.
/// Keeping the action behind an explicit catalog also lets XCUITest exercise
/// production routing without illegally invoking an intent outside that flow.
@MainActor
enum PortavozAppEntityOpenAction {
    static func openMeeting(
        _ target: PortavozMeetingEntity,
        catalog: any PortavozAppEntityCatalog
    ) async -> LocalizedStringResource {
        do {
            let matches = try await catalog.meetings(
                identifiers: [target.id],
                matching: nil,
                limit: 1)
            guard let current = matches.first else {
                PortavozAppIntentBridge.requestNavigation(.library)
                // One exact recovery sentence must remain a single localization key.
                return "That meeting is no longer available. Open Portavoz and choose another meeting from Library."
            }
            PortavozAppIntentBridge.requestNavigation(.meeting(target.id))
            return "Opening \(current.title)."
        } catch {
            PortavozAppIntentBridge.requestNavigation(.library)
            return "Portavoz could not read the library. Open Portavoz and use the recovery action shown."
        }
    }

    static func showPersonCommitments(
        _ target: PortavozPersonEntity,
        catalog: any PortavozAppEntityCatalog
    ) async -> LocalizedStringResource {
        do {
            let matches = try await catalog.people(
                identifiers: [target.id],
                matching: nil,
                limit: 1)
            guard let current = matches.first else {
                PortavozAppIntentBridge.requestNavigation(.commitments)
                return "That person is no longer available. Open Commitment Radar and choose another owner."
            }
            PortavozAppIntentBridge.requestNavigation(.person(target.id))
            return "Showing commitments for \(current.name)."
        } catch {
            PortavozAppIntentBridge.requestNavigation(.commitments)
            return "Portavoz could not read commitments. Open Portavoz and use the recovery action shown."
        }
    }

    static func openCommitment(
        _ target: PortavozCommitmentEntity,
        catalog: any PortavozAppEntityCatalog
    ) async -> LocalizedStringResource {
        do {
            let matches = try await catalog.commitments(
                identifiers: [target.id],
                matching: nil,
                limit: 1)
            guard let current = matches.first else {
                PortavozAppIntentBridge.requestNavigation(.commitments)
                return "That commitment is no longer available. Open Commitment Radar and choose another commitment."
            }
            PortavozAppIntentBridge.requestNavigation(.commitment(target.id))
            return "Opening \(current.title)."
        } catch {
            PortavozAppIntentBridge.requestNavigation(.commitments)
            return "Portavoz could not read commitments. Open Portavoz and use the recovery action shown."
        }
    }
}

struct OpenMeetingIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open meeting"

    @Parameter(title: "Meeting", requestValueDialog: "Which meeting?")
    var target: PortavozMeetingEntity

    @AppDependency(default: UnavailablePortavozAppEntityCatalog())
    private var catalog: any PortavozAppEntityCatalog

    init() {}

    init(target: PortavozMeetingEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await PortavozAppEntityOpenAction.openMeeting(
            target,
            catalog: catalog)
        return .result(dialog: IntentDialog(dialog))
    }
}

struct ShowPersonCommitmentsIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show person's commitments"

    @Parameter(title: "Person", requestValueDialog: "Whose commitments?")
    var target: PortavozPersonEntity

    @AppDependency(default: UnavailablePortavozAppEntityCatalog())
    private var catalog: any PortavozAppEntityCatalog

    init() {}

    init(target: PortavozPersonEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await PortavozAppEntityOpenAction.showPersonCommitments(
            target,
            catalog: catalog)
        return .result(dialog: IntentDialog(dialog))
    }
}

struct OpenCommitmentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open commitment"

    @Parameter(title: "Commitment", requestValueDialog: "Which commitment?")
    var target: PortavozCommitmentEntity

    @AppDependency(default: UnavailablePortavozAppEntityCatalog())
    private var catalog: any PortavozAppEntityCatalog

    init() {}

    init(target: PortavozCommitmentEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await PortavozAppEntityOpenAction.openCommitment(
            target,
            catalog: catalog)
        return .result(dialog: IntentDialog(dialog))
    }
}

// MARK: - Dictation

/// Starts or finishes dictation like the global shortcut. It runs in the
/// background so the app in front stays the destination of the text.
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate"
    static let description = IntentDescription(
        "Starts dictation into the app in front, or finishes the one in progress, without bringing Portavoz forward.")
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        try PortavozAppIntentBridge.requestDictation(.toggle).throwUnlessAccepted()
        return .result()
    }
}

/// Pastes the last dictation into the app in front, like Paste last.
struct PasteLastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste last dictation"
    static let description = IntentDescription(
        "Pastes your last dictation into the app in front, while Portavoz still remembers it.")
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        try PortavozAppIntentBridge.requestDictation(.pasteLast).throwUnlessAccepted()
        return .result()
    }
}

/// Saved dictation texts for a Shortcut, newest first. Each request checks
/// the same consent as local agents, in the same read as the rows.
struct SearchDictationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search dictations"
    static let description = IntentDescription(
        // swiftlint:disable:next line_length
        "Finds your saved dictations that contain these words, newest first. Works only while Portavoz lets agents and Shortcuts read the history.")
    static let supportedModes: IntentModes = [.background]

    @Parameter(title: "Words")
    var words: String?

    @Parameter(title: "Limit", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    @AppDependency(default: UnavailablePortavozDictationReader())
    private var reader: any PortavozDictationReader

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        .result(value: try await PortavozDictationSearchAction.search(words ?? "", limit: limit, reader: reader))
    }
}

/// Opens Portavoz on the dictation history, optionally searching for words.
struct OpenDictationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open dictations"
    static let description = IntentDescription(
        "Opens your saved dictations in Portavoz, optionally searching for words.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @Parameter(title: "Search")
    var search: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let words = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        PortavozAppIntentBridge.requestNavigation(.dictations(String(words.prefix(200))))
        return .result()
    }
}

/// App-installed read of saved dictations. nil means the user has not shared
/// the history with agents and Shortcuts; nothing was read.
protocol PortavozDictationReader: Sendable {
    func dictationTexts(matching words: String, limit: Int) async throws -> [String]?
}

struct UnavailablePortavozDictationReader: PortavozDictationReader {
    func dictationTexts(matching _: String, limit _: Int) async throws -> [String]? {
        throw PortavozDictationIntentError.notReady
    }
}

/// Called by the intent and by tests, since App Intents only fills
/// `@AppDependency` while it owns `perform()`.
enum PortavozDictationSearchAction {
    static func search(_ words: String, limit: Int, reader: any PortavozDictationReader) async throws -> [String] {
        let trimmed = String(words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard let texts = try await reader.dictationTexts(matching: trimmed, limit: min(max(limit, 1), 50)) else {
            throw PortavozDictationIntentError.notShared
        }
        return texts
    }
}

/// Why a dictation action did nothing. Shortcuts shows the message; success stays silent.
enum PortavozDictationIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notReady
    case dictationOff
    case busy
    case nothingToPaste
    case notShared

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            "Portavoz is still opening. Run the action again in a moment."
        case .dictationOff:
            "Dictation is off. Turn it on in Portavoz Settings › Audio & dictation."
        case .busy:
            "Portavoz is finishing the current dictation. Run the action again when it's done."
        case .nothingToPaste:
            "There's no recent dictation to paste."
        case .notShared:
            "Turn on “Let agents and Shortcuts read the history” in Portavoz Settings › Audio & dictation."
        }
    }
}

/// SDK-only process handoff shared by the intent and the app delegate.
///
/// App Intents metadata extraction compiles this file by itself, so the
/// bridge deliberately depends only on Foundation. The pending bit closes the
/// cold-launch race where `perform()` arrives before the delegate subscribes.
@MainActor
enum PortavozAppIntentBridge {
    enum NavigationRequest: Equatable {
        case library
        case commitments
        case meeting(String)
        case person(String)
        case commitment(String)
        /// Dictations, searching for these words when not empty.
        case dictations(String)
    }

    enum StopRecordingRequestDisposition: Equatable {
        case queued
        case accepted
        case noActiveRecording
        case recordingIsPreparing
        case alreadyStopping
        case recoveryRequired

        var dialog: LocalizedStringResource {
            switch self {
            case .queued:
                "Portavoz will handle the stop request after it finishes opening."
            case .accepted:
                "Portavoz is stopping the current recording."
            case .noActiveRecording:
                "No recording is active. Use Start recording to begin one."
            case .recordingIsPreparing:
                "Portavoz is still starting the recording. Run Stop recording again when the live controls appear."
            case .alreadyStopping:
                "Portavoz is already stopping the recording. Open Portavoz to view progress."
            case .recoveryRequired:
                "The recording needs attention. Open Portavoz and use the recovery action shown."
            }
        }
    }

    static let startRecordingRequested = Notification.Name(
        "app.portavoz.start-recording-intent")
    static let stopRecordingRequested = Notification.Name(
        "app.portavoz.stop-recording-intent")
    static let navigationRequested = Notification.Name(
        "app.portavoz.navigation-intent")
    static let dictationRequested = Notification.Name(
        "app.portavoz.dictation-intent")

    enum DictationRequest: Equatable {
        case toggle
        case pasteLast
    }

    enum DictationRequestOutcome: Equatable {
        case accepted
        case notReady
        case dictationOff
        case busy
        case nothingToPaste

        func throwUnlessAccepted() throws {
            switch self {
            case .accepted: return
            case .notReady: throw PortavozDictationIntentError.notReady
            case .dictationOff: throw PortavozDictationIntentError.dictationOff
            case .busy: throw PortavozDictationIntentError.busy
            case .nothingToPaste: throw PortavozDictationIntentError.nothingToPaste
            }
        }
    }

    private static var pendingDictationRequest: DictationRequest?
    private static var dictationOutcome = DictationRequestOutcome.notReady

    private static var hasPendingStartRecording = false
    private static var hasPendingStopRecording = false
    private static var stopRecordingDisposition:
        StopRecordingRequestDisposition = .queued
    /// Navigation is state replacement: while launch is blocked, the latest
    /// explicit user destination wins instead of building an unbounded queue.
    private static var pendingNavigationRequest: NavigationRequest?

    static func requestStartRecording() {
        hasPendingStartRecording = true
        notifyPendingStartRecordingRequest()
    }

    static func notifyPendingStartRecordingRequest() {
        guard hasPendingStartRecording else { return }
        NotificationCenter.default.post(
            name: startRecordingRequested,
            object: nil)
    }

    static func requestStopRecording() -> StopRecordingRequestDisposition {
        hasPendingStopRecording = true
        stopRecordingDisposition = .queued
        notifyPendingStopRecordingRequest()
        return stopRecordingDisposition
    }

    static func notifyPendingStopRecordingRequest() {
        guard hasPendingStopRecording else { return }
        NotificationCenter.default.post(
            name: stopRecordingRequested,
            object: nil)
    }

    /// Answered during the synchronous post and never replayed: dictating
    /// after a slow launch could put text into whatever app is in front then.
    static func requestDictation(_ request: DictationRequest) -> DictationRequestOutcome {
        pendingDictationRequest = request
        dictationOutcome = .notReady
        NotificationCenter.default.post(name: dictationRequested, object: nil)
        pendingDictationRequest = nil
        return dictationOutcome
    }

    static func consumeDictationRequest() -> DictationRequest? {
        defer { pendingDictationRequest = nil }
        return pendingDictationRequest
    }

    static func answerDictationRequest(_ outcome: DictationRequestOutcome) {
        dictationOutcome = outcome
    }

    static func requestNavigation(_ request: NavigationRequest) {
        pendingNavigationRequest = request
        notifyPendingNavigationRequest()
    }

    static func notifyPendingNavigationRequest() {
        guard pendingNavigationRequest != nil else { return }
        NotificationCenter.default.post(name: navigationRequested, object: nil)
    }

    @discardableResult
    static func consumeStartRecordingRequest() -> Bool {
        let pending = hasPendingStartRecording
        hasPendingStartRecording = false
        return pending
    }

    @discardableResult
    static func consumeStopRecordingRequest(
        as disposition: StopRecordingRequestDisposition
    ) -> Bool {
        guard hasPendingStopRecording else { return false }
        hasPendingStopRecording = false
        stopRecordingDisposition = disposition
        return true
    }

    static func consumeNavigationRequest() -> NavigationRequest? {
        defer { pendingNavigationRequest = nil }
        return pendingNavigationRequest
    }
}
