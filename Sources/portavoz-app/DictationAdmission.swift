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

/// The right to run one operation, held until its delivery and Stop have finished.
@MainActor
final class DictationLease {
    private var end: (() -> Void)?

    init(end: @escaping () -> Void = {}) {
        self.end = end
    }

    func release() {
        end?()
        end = nil
    }
}

/// The one port for every capture and delivery, whichever trigger asked.
/// A refusal never writes the user's preference.
@MainActor
struct DictationAdmission {
    var acquire: (DictationAdmissionKind) -> Result<DictationLease, DictationAdmissionRefusal>
    /// For work that needs no lease: prewarm and answering an Intent.
    var isEligible: () -> Bool

    static func preference(in defaults: UserDefaults) -> Self {
        let isOn = { defaults.bool(forKey: DictationController.defaultsKey) }
        return Self(
            acquire: { kind in
                kind == .practice || isOn() ? .success(DictationLease()) : .failure(.dictationOff)
            },
            isEligible: isOn)
    }
}

extension AppServices {
    var dictationAdmission: DictationAdmission { .preference(in: defaults) }
}
