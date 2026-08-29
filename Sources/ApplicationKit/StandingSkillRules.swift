import Foundation
import PortavozCore
import StorageKit

/// The deliberately closed AUTO-5 catalogue. Adding another template expands
/// unattended authority and therefore requires an independent product gate.
public enum StandingSkillRuleTemplate: String, CaseIterable, Sendable {
    case prepareEveryUpcomingBrief = "prepare-every-upcoming-brief"

    public static let defaultMaximumDailyExecutions = 3

    public var definition: SkillDefinition {
        switch self {
        case .prepareEveryUpcomingBrief:
            PreMeetingBriefSkill.definition
        }
    }

    public func makeRule(
        id: StandingSkillRuleID = StandingSkillRuleID(),
        maximumDailyExecutions: Int = Self.defaultMaximumDailyExecutions,
        at timestamp: Date
    ) -> StandingSkillRule {
        switch self {
        case .prepareEveryUpcomingBrief:
            StandingSkillRule(
                id: id,
                skillID: definition.id,
                skillVersion: definition.version,
                trigger: .upcomingCalendarEvent,
                subjectPredicate: .anyUpcomingCalendarEvent,
                action: .preparePreMeetingBrief,
                maximumDailyExecutions: maximumDailyExecutions,
                isEnabled: true,
                createdAt: timestamp,
                updatedAt: timestamp)
        }
    }

    public func matches(_ rule: StandingSkillRule) -> Bool {
        guard rule.isValid else { return false }
        let candidate = makeRule(
            id: rule.id,
            maximumDailyExecutions: rule.maximumDailyExecutions,
            at: rule.createdAt)
        return rule.skillID == candidate.skillID
            && rule.skillVersion == candidate.skillVersion
            && rule.trigger == candidate.trigger
            && rule.subjectPredicate == candidate.subjectPredicate
            && rule.action == candidate.action
    }
}

public protocol StandingSkillRuleStore: SkillExecutionPolicyReading, Sendable {
    func standingSkillRules(limit: Int) async throws -> [StandingSkillRule]
    func insertStandingSkillRule(
        _ rule: StandingSkillRule
    ) async throws -> StandingSkillRuleInsertionOutcome
    func setStandingSkillRule(
        _ id: StandingSkillRuleID,
        isEnabled: Bool,
        at timestamp: Date
    ) async throws -> Bool
    func deleteStandingSkillRule(_ id: StandingSkillRuleID) async throws -> Bool
}

extension MeetingStore: StandingSkillRuleStore {}

public enum StandingSkillRuleCompatibility: Equatable, Sendable {
    case current
    case staleDefinition
}

public struct StandingSkillRuleControlItem: Equatable, Identifiable, Sendable {
    public let rule: StandingSkillRule
    public let compatibility: StandingSkillRuleCompatibility
    public let isEffectivelyEnabled: Bool

    public var id: StandingSkillRuleID { rule.id }
}

public struct StandingSkillRuleControlSnapshot: Equatable, Sendable {
    public let isPaused: Bool
    public let rules: [StandingSkillRuleControlItem]
}

public struct LoadStandingSkillRules: ApplicationUseCase {
    private let store: any StandingSkillRuleStore

    public init(store: any StandingSkillRuleStore) {
        self.store = store
    }

    public func execute(
        _ request: Void
    ) async throws -> StandingSkillRuleControlSnapshot {
        async let policy = store.skillExecutionPolicy()
        async let rules = store.standingSkillRules(
            limit: StandingSkillRule.maximumRuleCount)
        let resolvedPolicy = try await policy
        let resolvedRules = try await rules
        return StandingSkillRuleControlSnapshot(
            isPaused: resolvedPolicy.isPaused,
            rules: resolvedRules.map { rule in
                let compatibility = compatibility(of: rule)
                return StandingSkillRuleControlItem(
                    rule: rule,
                    compatibility: compatibility,
                    isEffectivelyEnabled:
                        compatibility == .current
                            && rule.isEnabled
                            && resolvedPolicy.isEnabled(skillID: rule.skillID))
            })
    }

    private func compatibility(
        of rule: StandingSkillRule
    ) -> StandingSkillRuleCompatibility {
        StandingSkillRuleTemplate.allCases.contains(where: {
            $0.matches(rule)
        }) ? .current : .staleDefinition
    }
}

public struct CreateStandingSkillRuleRequest: Equatable, Sendable {
    public let template: StandingSkillRuleTemplate
    public let maximumDailyExecutions: Int

    public init(
        template: StandingSkillRuleTemplate,
        maximumDailyExecutions: Int =
            StandingSkillRuleTemplate.defaultMaximumDailyExecutions
    ) {
        self.template = template
        self.maximumDailyExecutions = maximumDailyExecutions
    }
}

public enum CreateStandingSkillRuleError: Error, Equatable, Sendable {
    case invalidDailyBudget
    case invalidTimestamp
    case staleExistingRule
    case capacityReached
}

public enum CreateStandingSkillRuleOutcome: Equatable, Sendable {
    case created(StandingSkillRule)
    case alreadyExists(StandingSkillRule)
}

public struct CreateStandingSkillRule: ApplicationUseCase {
    private let store: any StandingSkillRuleStore
    private let makeID: @Sendable () -> StandingSkillRuleID
    private let now: @Sendable () -> Date

    public init(
        store: any StandingSkillRuleStore,
        makeID: @escaping @Sendable () -> StandingSkillRuleID = {
            StandingSkillRuleID()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.makeID = makeID
        self.now = now
    }

    public func execute(
        _ request: CreateStandingSkillRuleRequest
    ) async throws -> CreateStandingSkillRuleOutcome {
        guard (1...StandingSkillRule.maximumDailyExecutionCount).contains(
            request.maximumDailyExecutions)
        else { throw CreateStandingSkillRuleError.invalidDailyBudget }
        let timestamp = now()
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw CreateStandingSkillRuleError.invalidTimestamp
        }
        let definition = request.template.definition
        guard definition.isValid,
              definition.isReversible,
              !definition.declaresExternalEffect,
              !definition.capabilities.contains(.writeLocalFile)
        else { throw CreateStandingSkillRuleError.staleExistingRule }
        let rule = request.template.makeRule(
            id: makeID(),
            maximumDailyExecutions: request.maximumDailyExecutions,
            at: timestamp)
        guard rule.isValid else {
            throw CreateStandingSkillRuleError.invalidDailyBudget
        }
        switch try await store.insertStandingSkillRule(rule) {
        case .inserted:
            return .created(rule)
        case .capacityReached:
            throw CreateStandingSkillRuleError.capacityReached
        case .duplicate:
            break
        }
        let existing = try await store.standingSkillRules(
            limit: StandingSkillRule.maximumRuleCount)
        guard let match = existing.first(where: {
            $0.trigger == rule.trigger
                && $0.subjectPredicate == rule.subjectPredicate
                && $0.action == rule.action
        }), request.template.matches(match)
        else { throw CreateStandingSkillRuleError.staleExistingRule }
        return .alreadyExists(match)
    }
}

public enum ManageStandingSkillRuleAction: Equatable, Sendable {
    case setEnabled(id: StandingSkillRuleID, isEnabled: Bool)
    case delete(id: StandingSkillRuleID)
}

public enum ManageStandingSkillRuleOutcome: Equatable, Sendable {
    case updated
    case deleted
    case notFound
    case staleDefinition
}

public struct ManageStandingSkillRule: ApplicationUseCase {
    private let store: any StandingSkillRuleStore
    private let now: @Sendable () -> Date

    public init(
        store: any StandingSkillRuleStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ action: ManageStandingSkillRuleAction
    ) async throws -> ManageStandingSkillRuleOutcome {
        switch action {
        case .delete(let id):
            return try await store.deleteStandingSkillRule(id)
                ? .deleted
                : .notFound
        case .setEnabled(let id, let isEnabled):
            let rules = try await store.standingSkillRules(
                limit: StandingSkillRule.maximumRuleCount)
            guard let rule = rules.first(where: { $0.id == id }) else {
                return .notFound
            }
            if isEnabled,
               !StandingSkillRuleTemplate.allCases.contains(where: {
                   $0.matches(rule)
               }) {
                return .staleDefinition
            }
            let timestamp = now()
            guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
                return .staleDefinition
            }
            return try await store.setStandingSkillRule(
                id,
                isEnabled: isEnabled,
                at: timestamp) ? .updated : .notFound
        }
    }
}
