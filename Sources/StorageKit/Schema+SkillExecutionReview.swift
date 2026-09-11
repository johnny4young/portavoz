import GRDB

extension StorageSchema {
    /// v39 (D336): newest-first partial indexes for each durable review scope.
    ///
    /// Each execution appears in exactly one partial index, so the three
    /// indexes together carry the same entry cardinality as one full index.
    /// The attention predicate intentionally admits unknown future states:
    /// hiding a potentially acted execution would be a fail-open downgrade.
    static func registerSkillExecutionReviewMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v39") { database in
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_waiting
                ON skillExecutionState(updatedAt DESC, proposalID ASC)
                WHERE state = 'confirmed'
                """)
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_attention
                ON skillExecutionState(updatedAt DESC, proposalID ASC)
                WHERE state NOT IN ('confirmed', 'succeeded', 'cancelled')
                """)
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_completed
                ON skillExecutionState(updatedAt DESC, proposalID ASC)
                WHERE state IN ('succeeded', 'cancelled')
                """)
        }
    }
}
