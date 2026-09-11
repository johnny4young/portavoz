/// One stable presentation value for Portavoz's primary WindowGroup. Opening
/// this exact value brings the existing main window forward instead of
/// creating another library window.
enum MainWindowIdentity: String, Codable, Hashable, Sendable {
    case primary
}
