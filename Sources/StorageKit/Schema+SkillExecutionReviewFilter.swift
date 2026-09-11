import GRDB

extension StorageSchema {
    /// v42 (D373): exact Skill-filtered newest-first execution review indexes.
    ///
    /// Unfiltered review keeps the v35/v39 indexes. Each filtered execution is
    /// present in one complete index plus exactly one state-scoped partial
    /// index, avoiding a full-history scan or temporary sort for sparse Skills.
    static func registerSkillExecutionReviewFilterMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v42") { database in
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_recent_skill
                ON skillExecutionState(
                    skillID, updatedAt DESC, proposalID ASC
                )
                """)
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_waiting_skill
                ON skillExecutionState(
                    skillID, updatedAt DESC, proposalID ASC
                )
                WHERE state = 'confirmed'
                """)
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_attention_skill
                ON skillExecutionState(
                    skillID, updatedAt DESC, proposalID ASC
                )
                WHERE state NOT IN ('confirmed', 'succeeded', 'cancelled')
                """)
            try database.execute(sql: """
                CREATE INDEX skillExecutionState_on_completed_skill
                ON skillExecutionState(
                    skillID, updatedAt DESC, proposalID ASC
                )
                WHERE state IN ('succeeded', 'cancelled')
                """)
        }
    }
}
