#include "include/CSQLiteVecResearch.h"

#define SQLITE_CORE 1
#define SQLITE_VEC_STATIC 1
#define SQLITE_VEC_OMIT_FS 1
#include "../../Vendor/sqlite-vec/sqlite-vec.c"

#include <math.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

struct PortavozSQLiteVecIndex {
  sqlite3 *database;
  int32_t vector_count;
  int32_t dimension;
};

struct PortavozSQLiteVecCancellation {
  atomic_bool cancelled;
};

static bool portavoz_sqlite_vec_values_are_finite(const float *values,
                                                   size_t count) {
  if (count > 0 && values == NULL) {
    return false;
  }
  for (size_t index = 0; index < count; index++) {
    if (!isfinite(values[index])) {
      return false;
    }
  }
  return true;
}

static int portavoz_sqlite_vec_was_cancelled(void *context) {
  PortavozSQLiteVecCancellation *cancellation = context;
  return cancellation != NULL &&
         atomic_load_explicit(&cancellation->cancelled,
                              memory_order_relaxed);
}

PortavozSQLiteVecCancellation *portavoz_sqlite_vec_cancellation_create(void) {
  PortavozSQLiteVecCancellation *cancellation =
      malloc(sizeof(PortavozSQLiteVecCancellation));
  if (cancellation != NULL) {
    atomic_init(&cancellation->cancelled, false);
  }
  return cancellation;
}

void portavoz_sqlite_vec_cancellation_cancel(
    PortavozSQLiteVecCancellation *cancellation) {
  if (cancellation != NULL) {
    atomic_store_explicit(&cancellation->cancelled, true,
                          memory_order_relaxed);
  }
}

void portavoz_sqlite_vec_cancellation_destroy(
    PortavozSQLiteVecCancellation *cancellation) {
  free(cancellation);
}

int portavoz_sqlite_vec_index_create(const float *vectors,
                                     int32_t vector_count,
                                     int32_t dimension,
                                     PortavozSQLiteVecIndex **out_index) {
  if (out_index == NULL || vector_count < 0 || dimension <= 0 ||
      dimension > INT32_MAX / (int32_t)sizeof(float)) {
    return SQLITE_MISUSE;
  }
  *out_index = NULL;
  const size_t scalar_count = (size_t)vector_count * (size_t)dimension;
  if (vector_count > 0 && scalar_count / (size_t)dimension !=
                              (size_t)vector_count) {
    return SQLITE_TOOBIG;
  }
  if (!portavoz_sqlite_vec_values_are_finite(vectors, scalar_count)) {
    return SQLITE_MISMATCH;
  }

  PortavozSQLiteVecIndex *index =
      sqlite3_malloc64(sizeof(PortavozSQLiteVecIndex));
  if (index == NULL) {
    return SQLITE_NOMEM;
  }
  index->database = NULL;
  index->vector_count = vector_count;
  index->dimension = dimension;

  char *extension_error = NULL;
  char *schema = NULL;
  sqlite3_stmt *insert = NULL;
  bool transaction_open = false;
  int result = sqlite3_open(":memory:", &index->database);
  if (result != SQLITE_OK) {
    goto cleanup;
  }
  result = sqlite3_vec_init(index->database, &extension_error, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  schema = sqlite3_mprintf(
      "CREATE VIRTUAL TABLE research_vectors USING "
      "vec0(embedding float[%d] distance_metric=cosine)",
      dimension);
  if (schema == NULL) {
    result = SQLITE_NOMEM;
    goto cleanup;
  }
  result = sqlite3_exec(index->database, schema, NULL, NULL, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  result = sqlite3_exec(index->database, "BEGIN IMMEDIATE", NULL, NULL, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }
  transaction_open = true;
  result = sqlite3_prepare_v2(
      index->database,
      "INSERT INTO research_vectors(rowid, embedding) VALUES (?1, ?2)", -1,
      &insert, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  const int vector_bytes = dimension * (int32_t)sizeof(float);
  for (int32_t position = 0; position < vector_count; position++) {
    result = sqlite3_bind_int64(insert, 1, (sqlite3_int64)position + 1);
    if (result != SQLITE_OK) {
      goto cleanup;
    }
    result = sqlite3_bind_blob(
        insert, 2, vectors + ((size_t)position * (size_t)dimension),
        vector_bytes, SQLITE_TRANSIENT);
    if (result != SQLITE_OK) {
      goto cleanup;
    }
    result = sqlite3_step(insert);
    if (result != SQLITE_DONE) {
      goto cleanup;
    }
    result = sqlite3_reset(insert);
    if (result != SQLITE_OK) {
      goto cleanup;
    }
    result = sqlite3_clear_bindings(insert);
    if (result != SQLITE_OK) {
      goto cleanup;
    }
  }
  sqlite3_finalize(insert);
  insert = NULL;
  result = sqlite3_exec(index->database, "COMMIT", NULL, NULL, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }
  transaction_open = false;
  *out_index = index;

cleanup:
  sqlite3_finalize(insert);
  if (result != SQLITE_OK && transaction_open) {
    sqlite3_exec(index->database, "ROLLBACK", NULL, NULL, NULL);
  }
  sqlite3_free(schema);
  sqlite3_free(extension_error);
  if (result != SQLITE_OK) {
    if (index->database != NULL) {
      sqlite3_close(index->database);
    }
    sqlite3_free(index);
  }
  return result;
}

void portavoz_sqlite_vec_index_destroy(PortavozSQLiteVecIndex *index) {
  if (index != NULL) {
    if (index->database != NULL) {
      sqlite3_close(index->database);
    }
    sqlite3_free(index);
  }
}

int portavoz_sqlite_vec_index_rank(
    PortavozSQLiteVecIndex *index,
    const float *query,
    int32_t dimension,
    int32_t limit,
    int32_t *out_indices,
    int32_t out_capacity,
    int32_t *out_count,
    PortavozSQLiteVecCancellation *cancellation) {
  if (index == NULL || out_count == NULL || dimension != index->dimension ||
      limit < 0 || out_capacity < 0 || limit > out_capacity ||
      (limit > 0 && out_indices == NULL) ||
      !portavoz_sqlite_vec_values_are_finite(query, (size_t)dimension)) {
    return SQLITE_MISUSE;
  }
  *out_count = 0;
  if (limit == 0 || index->vector_count == 0) {
    return SQLITE_OK;
  }
  if (portavoz_sqlite_vec_was_cancelled(cancellation)) {
    return SQLITE_INTERRUPT;
  }

  const int32_t requested =
      limit < index->vector_count ? limit : index->vector_count;
  sqlite3_stmt *statement = NULL;
  double *distances = sqlite3_malloc64((sqlite3_uint64)requested * sizeof(double));
  if (distances == NULL) {
    return SQLITE_NOMEM;
  }
  sqlite3_progress_handler(index->database, 1000,
                           portavoz_sqlite_vec_was_cancelled, cancellation);
  int result = sqlite3_prepare_v2(
      index->database,
      "SELECT rowid, distance FROM research_vectors "
      "WHERE embedding MATCH ?1 ORDER BY distance LIMIT ?2",
      -1, &statement, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }
  result = sqlite3_bind_blob(statement, 1, query,
                             dimension * (int32_t)sizeof(float),
                             SQLITE_TRANSIENT);
  if (result != SQLITE_OK) {
    goto cleanup;
  }
  result = sqlite3_bind_int(statement, 2, index->vector_count);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
    const sqlite3_int64 rowid = sqlite3_column_int64(statement, 0);
    const double distance = sqlite3_column_double(statement, 1);
    if (rowid <= 0 || rowid > index->vector_count) {
      result = SQLITE_CORRUPT;
      goto cleanup;
    }
    if (!isfinite(distance)) {
      result = SQLITE_MISMATCH;
      goto cleanup;
    }
    const int32_t candidate = (int32_t)(rowid - 1);
    int32_t insertion = 0;
    while (insertion < *out_count &&
           (distances[insertion] < distance ||
            (distances[insertion] == distance &&
             out_indices[insertion] < candidate))) {
      insertion += 1;
    }
    if (insertion >= requested) {
      continue;
    }
    const int32_t next_count =
        *out_count < requested ? *out_count + 1 : requested;
    for (int32_t position = next_count - 1; position > insertion; position--) {
      distances[position] = distances[position - 1];
      out_indices[position] = out_indices[position - 1];
    }
    distances[insertion] = distance;
    out_indices[insertion] = candidate;
    *out_count = next_count;
  }
  if (result == SQLITE_DONE) {
    result = SQLITE_OK;
  }

cleanup:
  sqlite3_finalize(statement);
  sqlite3_free(distances);
  sqlite3_progress_handler(index->database, 0, NULL, NULL);
  if (result != SQLITE_OK) {
    *out_count = 0;
  }
  return result;
}

int portavoz_sqlite_vec_run_exact_query_smoke(void) {
  static const float vectors[][4] = {
      {1.0f, 0.0f, 0.0f, 0.0f},
      {0.0f, 1.0f, 0.0f, 0.0f},
      {0.0f, 0.0f, 1.0f, 0.0f},
      {0.0f, 0.0f, 0.0f, 1.0f},
  };
  PortavozSQLiteVecIndex *index = NULL;
  int result = portavoz_sqlite_vec_index_create(
      &vectors[0][0], 4, 4, &index);
  if (result != SQLITE_OK) {
    return result;
  }
  const float query[4] = {0.0f, 0.0f, 1.0f, 0.0f};
  int32_t nearest = -1;
  int32_t count = 0;
  result = portavoz_sqlite_vec_index_rank(
      index, query, 4, 1, &nearest, 1, &count, NULL);
  if (result == SQLITE_OK && (count != 1 || nearest != 2)) {
    result = SQLITE_ERROR;
  }
  portavoz_sqlite_vec_index_destroy(index);
  return result;
}
