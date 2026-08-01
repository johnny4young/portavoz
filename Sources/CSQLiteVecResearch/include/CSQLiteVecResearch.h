#ifndef PORTAVOZ_CSQLITE_VEC_RESEARCH_H
#define PORTAVOZ_CSQLITE_VEC_RESEARCH_H

#include <stdint.h>

typedef struct PortavozSQLiteVecIndex PortavozSQLiteVecIndex;
typedef struct PortavozSQLiteVecCancellation PortavozSQLiteVecCancellation;

/// Builds one disposable in-memory `vec0` exact index over row-ordered vectors.
/// Returns a SQLite result code and publishes no partially initialized index.
int portavoz_sqlite_vec_index_create(const float *vectors,
                                     int32_t vector_count,
                                     int32_t dimension,
                                     PortavozSQLiteVecIndex **out_index);

void portavoz_sqlite_vec_index_destroy(PortavozSQLiteVecIndex *index);

/// Returns zero-based vector positions in exact cosine-distance order.
/// Returns `SQLITE_INTERRUPT` when cancellation is observed before or by
/// SQLite during execution.
int portavoz_sqlite_vec_index_rank(
    PortavozSQLiteVecIndex *index,
    const float *query,
    int32_t dimension,
    int32_t limit,
    int32_t *out_indices,
    int32_t out_capacity,
    int32_t *out_count,
    PortavozSQLiteVecCancellation *cancellation);

PortavozSQLiteVecCancellation *portavoz_sqlite_vec_cancellation_create(void);
void portavoz_sqlite_vec_cancellation_cancel(
    PortavozSQLiteVecCancellation *cancellation);
void portavoz_sqlite_vec_cancellation_destroy(
    PortavozSQLiteVecCancellation *cancellation);

/// Runs one in-memory, exact `vec0` nearest-neighbor query over fixed vectors.
/// Returns `SQLITE_OK` only when row 3 is the deterministic nearest result.
int portavoz_sqlite_vec_run_exact_query_smoke(void);

#endif
