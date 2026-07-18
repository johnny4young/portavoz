import IntegrationsKit
import XCTest

final class CloudKitMeetingSyncPlatformTests: XCTestCase {
    func testCompleteSignedCapabilitySetIsAvailable() {
        let report = CloudKitMeetingSyncCapabilityProbe.evaluate(
            CloudKitMeetingSyncSignedCapabilities(
                containerIdentifiers: ["iCloud.app.portavoz.mac"],
                services: ["CloudKit"],
                containerEnvironment: "Production",
                pushEnvironment: "production",
                hasEmbeddedProvisioningProfile: true))

        XCTAssertTrue(report.isAvailable)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testDevelopmentProfileValuesAreAcceptedForLocalDevelopment() {
        let report = CloudKitMeetingSyncCapabilityProbe.evaluate(
            CloudKitMeetingSyncSignedCapabilities(
                containerIdentifiers: ["iCloud.app.portavoz.mac"],
                services: ["CloudKit"],
                containerEnvironment: "Development",
                pushEnvironment: "development",
                hasEmbeddedProvisioningProfile: true))

        XCTAssertTrue(report.isAvailable)
    }

    func testEveryRestrictedCapabilityAndProfileIsRequired() {
        let report = CloudKitMeetingSyncCapabilityProbe.evaluate(
            CloudKitMeetingSyncSignedCapabilities(
                containerIdentifiers: [],
                services: [],
                containerEnvironment: nil,
                pushEnvironment: nil,
                hasEmbeddedProvisioningProfile: false))

        XCTAssertEqual(
            report.issues,
            [
                .missingContainer,
                .missingCloudKitService,
                .missingContainerEnvironment,
                .missingPushEnvironment,
                .missingProvisioningProfile
            ])
    }

    func testWrongContainerAndEnvironmentFailClosed() {
        let report = CloudKitMeetingSyncCapabilityProbe.evaluate(
            CloudKitMeetingSyncSignedCapabilities(
                containerIdentifiers: ["iCloud.example.wrong"],
                services: ["CloudKit"],
                containerEnvironment: "Sandbox",
                pushEnvironment: "sandbox",
                hasEmbeddedProvisioningProfile: true))

        XCTAssertEqual(
            report.issues,
            [.missingContainer, .missingContainerEnvironment, .missingPushEnvironment])
    }

    func testCloudKitAndPushEnvironmentsMustMatch() {
        let report = CloudKitMeetingSyncCapabilityProbe.evaluate(
            CloudKitMeetingSyncSignedCapabilities(
                containerIdentifiers: ["iCloud.app.portavoz.mac"],
                services: ["CloudKit"],
                containerEnvironment: "Production",
                pushEnvironment: "development",
                hasEmbeddedProvisioningProfile: true))

        XCTAssertEqual(report.issues, [.environmentMismatch])
    }
}
