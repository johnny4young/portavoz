#ifndef PORTAVOZ_CSQLITE_VEC_RESEARCH_H
#define PORTAVOZ_CSQLITE_VEC_RESEARCH_H

/// Runs one in-memory, exact `vec0` nearest-neighbor query over fixed vectors.
/// Returns `SQLITE_OK` only when row 3 is the deterministic nearest result.
int portavoz_sqlite_vec_run_exact_query_smoke(void);

#endif
