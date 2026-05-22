#pragma once
#include <stdint.h>
#include <stddef.h>

/* Opaque database handle */
typedef struct IcrDb IcrDb;

/* Open / close ----------------------------------------------------------------
 * conninfo: standard libpq connection string, e.g. "dbname=icarium host=localhost"
 * Returns NULL on failure.  Thread-safe to call concurrently with different
 * IcrDb instances; do NOT share one IcrDb across threads. */
IcrDb *icr_db_open(const char *conninfo);
void   icr_db_close(IcrDb *db);

/* Apply DDL from schema/001_init.sql inline (idempotent).
 * Returns 0 on success, -1 on error. */
int icr_db_migrate(IcrDb *db);

/* Task queue -----------------------------------------------------------------
 * All functions return 0 on success, -1 on error.
 * task_id_out receives the new BIGSERIAL id on icr_task_insert(). */
int icr_task_insert(IcrDb *db, const char *kind, const char *params_json,
                    int64_t *task_id_out);
int icr_task_start(IcrDb *db, int64_t task_id);
int icr_task_done(IcrDb *db, int64_t task_id, int exit_code,
                  const char *stdout_tail);
int icr_task_fail(IcrDb *db, int64_t task_id, const char *err_msg);

/* Serialise the N most recent tasks as a JSON array into out[0..out_size-1].
 * Always null-terminates.  Returns 0 on success, -1 on error. */
int icr_task_list_json(IcrDb *db, int limit, char *out, size_t out_size);

/* Project management ---------------------------------------------------------
 * Returns project id (>0) on success, -1 on error. */
int64_t icr_project_get_or_create(IcrDb *db, const char *name,
                                   const char *root_path);

/* Entity insertion -----------------------------------------------------------
 * Inserts one NER-extracted entity; ON CONFLICT (project,file,kind,name,line)
 * DO NOTHING — safe to re-index.
 * entity_id_out receives the new or existing id.
 * Returns 0 on success, -1 on error. */
int icr_entity_insert(IcrDb *db, int64_t project_id, const char *kind,
                      const char *name, const char *file_path,
                      int line_start, int line_end, float confidence,
                      int64_t *entity_id_out);

/* Delete all entities for a given file (call before re-indexing). */
int icr_entities_delete_file(IcrDb *db, int64_t project_id,
                              const char *file_path);

/* Shell execution ------------------------------------------------------------
 * Runs cmd via /bin/sh -c, captures stdout (up to out_size-1 bytes).
 * Always null-terminates stdout_out.
 * Writes WEXITSTATUS into *exit_code_out.
 * Returns 0 if the child process was launched and reaped (regardless of its
 * exit code), -1 if popen/pclose failed. */
int icr_exec_shell(const char *cmd, char *stdout_out, size_t out_size,
                   int *exit_code_out);
