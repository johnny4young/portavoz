import GRDB

extension StorageSchema {
    /// Polish dictation: history rows may carry the mode, and a local engine
    /// rewrite leaves a content-free receipt in the global egress journal.
    static func registerDictationPolishMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v59") { db in
            try admitPolishDictationMode(in: db)
            try admitDictationPolishEgress(in: db)
        }
    }
}
