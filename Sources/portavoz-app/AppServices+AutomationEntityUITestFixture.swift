import Foundation

extension AppServices {
    /// Runs only after the disposable aggregate is seeded. Building the target
    /// through the production catalog avoids a test-only entity shortcut.
    func routeAutomationEntityIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-use-temp-store"),
              let marker = arguments.firstIndex(of: "-simulate-app-entity-route"),
              arguments.indices.contains(marker + 1)
        else { return }

        let catalog = AppAutomationEntityCatalog(store: store)
        do {
            switch arguments[marker + 1] {
            case "meeting":
                guard let target = try await catalog.meetings(
                    identifiers: nil,
                    matching: "Test meeting",
                    limit: 1).first
                else { return assertionFailure("Missing Meeting App Entity fixture") }
                _ = await PortavozAppEntityOpenAction.openMeeting(
                    target,
                    catalog: catalog)
            case "person":
                guard let target = try await catalog.people(
                    identifiers: nil,
                    matching: "Ana",
                    limit: 1).first
                else { return assertionFailure("Missing Person App Entity fixture") }
                _ = await PortavozAppEntityOpenAction.showPersonCommitments(
                    target,
                    catalog: catalog)
            case "commitment":
                guard let target = try await catalog.commitments(
                    identifiers: nil,
                    matching: "Send the rollout brief",
                    limit: 1).first
                else { return assertionFailure("Missing Commitment App Entity fixture") }
                _ = await PortavozAppEntityOpenAction.openCommitment(
                    target,
                    catalog: catalog)
            default:
                assertionFailure("Unknown App Entity route fixture")
            }
        } catch {
            assertionFailure("Could not route the App Entity fixture: \(error)")
        }
    }
}
