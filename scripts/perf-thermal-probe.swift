import Foundation

// Use the same public signal as the native resource benchmark. The absence
// of a pmset warning does not establish a nominal Foundation thermal state.
switch ProcessInfo.processInfo.thermalState {
case .nominal: print("nominal")
case .fair: print("fair")
case .serious: print("serious")
case .critical: print("critical")
@unknown default: print("unknown")
}
