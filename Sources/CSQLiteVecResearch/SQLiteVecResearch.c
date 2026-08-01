#include "include/CSQLiteVecResearch.h"

#define SQLITE_CORE 1
#define SQLITE_VEC_STATIC 1
#define SQLITE_VEC_OMIT_FS 1
#include "../../Vendor/sqlite-vec/sqlite-vec.c"

#include <math.h>
#include <stddef.h>

int portavoz_sqlite_vec_run_exact_query_smoke(void) {
  sqlite3 *database = NULL;
  sqlite3_stmt *statement = NULL;
  char *extension_error = NULL;
  int result = sqlite3_open(":memory:", &database);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  result = sqlite3_vec_init(database, &extension_error, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  result = sqlite3_exec(
      database,
      "CREATE VIRTUAL TABLE research_vectors USING vec0(embedding float[4])",
      NULL, NULL, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  result = sqlite3_prepare_v2(
      database,
      "INSERT INTO research_vectors(rowid, embedding) VALUES (?1, ?2)", -1,
      &statement, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }

  static const struct {
    sqlite3_int64 rowid;
    float vector[4];
  } items[] = {
      {1, {0.1f, 0.1f, 0.1f, 0.1f}},
      {2, {0.2f, 0.2f, 0.2f, 0.2f}},
      {3, {0.3f, 0.3f, 0.3f, 0.3f}},
      {4, {0.4f, 0.4f, 0.4f, 0.4f}},
  };
  for (size_t index = 0; index < sizeof(items) / sizeof(items[0]); index++) {
    sqlite3_bind_int64(statement, 1, items[index].rowid);
    sqlite3_bind_blob(statement, 2, items[index].vector,
                      (int)sizeof(items[index].vector), SQLITE_STATIC);
    result = sqlite3_step(statement);
    if (result != SQLITE_DONE) {
      goto cleanup;
    }
    result = sqlite3_reset(statement);
    if (result != SQLITE_OK) {
      goto cleanup;
    }
    sqlite3_clear_bindings(statement);
  }
  sqlite3_finalize(statement);
  statement = NULL;

  result = sqlite3_prepare_v2(
      database,
      "SELECT rowid, distance FROM research_vectors "
      "WHERE embedding MATCH ?1 ORDER BY distance LIMIT 1",
      -1, &statement, NULL);
  if (result != SQLITE_OK) {
    goto cleanup;
  }
  const float query[4] = {0.3f, 0.3f, 0.3f, 0.3f};
  sqlite3_bind_blob(statement, 1, query, (int)sizeof(query), SQLITE_STATIC);

  result = sqlite3_step(statement);
  if (result != SQLITE_ROW || sqlite3_column_int64(statement, 0) != 3 ||
      fabs(sqlite3_column_double(statement, 1)) > 0.000001) {
    result = SQLITE_ERROR;
    goto cleanup;
  }
  result = sqlite3_step(statement);
  if (result == SQLITE_DONE) {
    result = SQLITE_OK;
  } else {
    result = SQLITE_ERROR;
  }

cleanup:
  sqlite3_finalize(statement);
  sqlite3_free(extension_error);
  if (database != NULL) {
    const int close_result = sqlite3_close(database);
    if (result == SQLITE_OK && close_result != SQLITE_OK) {
      result = close_result;
    }
  }
  return result;
}
