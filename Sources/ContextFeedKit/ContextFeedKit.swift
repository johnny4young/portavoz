import PortavozCore

/// `ContextItem` moved to PortavozCore (D28: StorageKit persists it and
/// IntelligenceKit weaves it into summaries — Kits only share types via
/// Core). The alias keeps existing `import ContextFeedKit` call sites
/// compiling.
public typealias ContextItem = PortavozCore.ContextItem
