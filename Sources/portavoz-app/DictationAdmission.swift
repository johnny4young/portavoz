import Foundation

/// A global operation captures or delivers outside this app. Practice only delivers
/// to the app's own field, so it runs whatever the global preference says.
enum DictationAdmissionKind: Equatable, Sendable {
    case global
    case practice
}

enum DictationAdmissionRefusal: Error, Equatable, Sendable {
    case dictationOff
}

/// The right to run one operation, held until its delivery, its clipboard restore
/// and Stop have finished.
@MainActor
final class DictationLease {
    private let settle: () async -> Void
    private var end: (() -> Void)?

    init(settle: @escaping () async -> Void = {}, end: @escaping () -> Void = {}) {
        self.settle = settle
        self.end = end
    }

    func release() {
        end?()
        end = nil
    }

    /// A cancelled caller cannot cut this short: the clipboard is still on loan.
    func releaseAfterDelivery() async {
        await Task { await settle() }.value
        release()
    }
}

/// The one port for every capture and delivery, whichever trigger asked.
/// A refusal never writes the user's preference.
@MainActor
struct DictationAdmission {
    var acquire: (DictationAdmissionKind) -> Result<DictationLease, DictationAdmissionRefusal>
    /// For work that needs no lease: prewarm and answering an Intent.
    var isEligible: () -> Bool

    static func preference(in defaults: UserDefaults, settle: @escaping () async -> Void = {}) -> Self {
        let isOn = { defaults.bool(forKey: DictationController.defaultsKey) }
        return Self(
            acquire: { kind in
                kind == .practice || isOn() ? .success(DictationLease(settle: settle)) : .failure(.dictationOff)
            },
            isEligible: isOn)
    }
}

extension AppServices {
    var dictationAdmission: DictationAdmission {
        .preference(in: defaults) { _ = await DictationClipboard.shared.waitForRestoration(on: .general) }
    }
}
