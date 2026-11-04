import DictationOwnership
import Foundation

/// A global operation captures or delivers outside this app. Practice only delivers
/// to the app's own field, so it runs whatever the global preference says.
enum DictationAdmissionKind: Equatable, Sendable {
    case global
    case practice
}

enum DictationAdmissionRefusal: Error, Equatable, Sendable {
    case dictationOff
    case busy
    case transferring
    case notOwner
    case unavailable(UnavailableReason)
}

/// The right to run one operation, held until its delivery, its clipboard restore
/// and Stop have finished.
@MainActor
final class DictationLease {
    /// Tells a replace apart from the read it follows, when the owner went away and came back.
    let generation: Int?
    private let confirm: () -> Bool
    private let settle: () async -> Void
    private var finishWork: (() -> Void)?
    private var end: (() -> Void)?

    init(
        generation: Int? = nil, revalidate: @escaping () -> Bool = { true },
        settle: @escaping () async -> Void = {}, finishWork: @escaping () -> Void = {},
        end: @escaping () -> Void = {}
    ) {
        self.generation = generation
        confirm = revalidate
        self.settle = settle
        self.finishWork = finishWork
        self.end = end
    }

    /// Call immediately before delivering. On false, keep the text and do not paste.
    func revalidate() -> Bool { confirm() }

    func release() {
        markWorkFinished()
        end?()
        end = nil
    }

    /// A cancelled caller cannot cut this short: the clipboard is still on loan.
    /// Another session may share the lease from here on.
    func releaseAfterDelivery() async {
        markWorkFinished()
        await Task { await settle() }.value
        release()
    }

    private func markWorkFinished() {
        finishWork?()
        finishWork = nil
    }
}

/// The one port for every capture and delivery, whichever trigger asked.
/// A refusal never writes the user's preference.
@MainActor
struct DictationAdmission {
    var acquire: (DictationAdmissionKind) -> Result<DictationLease, DictationAdmissionRefusal>
    /// For work that needs no lease: prewarm and answering an Intent.
    var isEligible: () -> Bool

    /// Asks and lets go at once, for an answer that has to come before the work starts.
    func refusalNow(for kind: DictationAdmissionKind = .global) -> DictationAdmissionRefusal? {
        switch acquire(kind) {
        case .success(let lease):
            lease.release()
            return nil
        case .failure(let refusal):
            return refusal
        }
    }
}

extension AppServices {
    var dictationAdmission: DictationAdmission { dictationOwnership.admission }

    /// What may be armed right now: the preference alone is not enough once another app owns dictation.
    var dictationTriggersMayArm: Bool { dictationOwnership.armsTriggers }

    func syncDictationTriggers(promptIfNeeded: Bool = false) {
        dictation.syncHotkey(services: self)
        syncPasteLastShortcut()
        syncRewriteSelectionShortcut()
        dictation.syncMousePTT(services: self, promptIfNeeded: promptIfNeeded)
        dictation.syncModifierPTT(services: self, promptIfNeeded: promptIfNeeded)
    }

    func connectDictationOwnership() {
        dictationOwnership.onStateChange = { [weak self] previous in
            guard let self else { return }
            syncDictationTriggers()
            if previous.allowsPrewarm, !dictationOwnership.state.allowsPrewarm {
                Task { await self.releaseIdleModel(.liveSpeech) }
            } else {
                prewarmDictationIfConfigured()
            }
        }
        dictationOwnership.onIntentChange = { [weak self] isLive in
            guard let self else { return }
            if isLive { dictation.ownershipIntentSeen() } else { dictation.ownershipIntentCleared() }
        }
    }
}
