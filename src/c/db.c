#include "db.h"
#include <libpq-fe.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

struct IcrDb {
    PGconn *conn;
};

IcrDb *icr_db_open(const char *conninfo) {
    IcrDb *db = calloc(1, sizeof(IcrDb));
    if (!db) return NULL;

    db->conn = PQconnectdb(conninfo);
    if (PQstatus(db->conn) != CONNECTION_OK) {
        fprintf(stderr, "icr_db_open: %s\n", PQerrorMessage(db->conn));
        PQfinish(db->conn);
        free(db);
        return NULL;
    }
    return db;
}

void icr_db_close(IcrDb *db) {
    if (!db) return;
    PQfinish(db->conn);
    free(db);
}

int icr_db_migrate(IcrDb *db) {
    const char *ddl =
        "CREATE TABLE IF NOT EXISTS icarium_projects ("
        "  id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE,"
        "  root_path TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

        "CREATE TABLE IF NOT EXISTS tasks ("
        "  id BIGSERIAL PRIMARY KEY, kind TEXT NOT NULL,"
        "  state TEXT NOT NULL DEFAULT 'pending',"
        "  params JSONB NOT NULL DEFAULT '{}',"
        "  stdout_tail TEXT, exit_code INT, result JSONB,"
        "  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "  started_at TIMESTAMPTZ, completed_at TIMESTAMPTZ);"

        "CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);"
        "CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC);"

        "CREATE TABLE IF NOT EXISTS findings ("
        "  id BIGSERIAL PRIMARY KEY, kind TEXT NOT NULL,"
        "  task_id BIGINT REFERENCES tasks(id) ON DELETE SET NULL,"
        "  data JSONB NOT NULL, confidence FLOAT,"
        "  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());";

    PGresult *res = PQexec(db->conn, ddl);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok)
        fprintf(stderr, "icr_db_migrate: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

/* ── Task queue ─────────────────────────────────────────────────────────────── */

int icr_task_insert(IcrDb *db, const char *kind, const char *params_json,
                    int64_t *task_id_out) {
    const char *sql =
        "INSERT INTO tasks(kind, params) VALUES($1, $2::jsonb) RETURNING id";
    const char *params[2] = { kind, params_json };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "icr_task_insert: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        return -1;
    }
    *task_id_out = atoll(PQgetvalue(res, 0, 0));
    PQclear(res);
    return 0;
}

int icr_task_start(IcrDb *db, int64_t task_id) {
    const char *sql =
        "UPDATE tasks SET state='running', started_at=NOW() WHERE id=$1";
    char id_str[24];
    snprintf(id_str, sizeof(id_str), "%lld", (long long)task_id);
    const char *params[1] = { id_str };
    PGresult *res = PQexecParams(db->conn, sql, 1, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "icr_task_start: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

int icr_task_done(IcrDb *db, int64_t task_id, int exit_code,
                  const char *stdout_tail) {
    const char *sql =
        "UPDATE tasks SET state='done', exit_code=$2, stdout_tail=$3,"
        " completed_at=NOW() WHERE id=$1";
    char id_str[24], code_str[12];
    snprintf(id_str,   sizeof(id_str),   "%lld", (long long)task_id);
    snprintf(code_str, sizeof(code_str), "%d",   exit_code);
    const char *params[3] = { id_str, code_str, stdout_tail };
    PGresult *res = PQexecParams(db->conn, sql, 3, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "icr_task_done: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

int icr_task_fail(IcrDb *db, int64_t task_id, const char *err_msg) {
    const char *sql =
        "UPDATE tasks SET state='failed', stdout_tail=$2,"
        " completed_at=NOW() WHERE id=$1";
    char id_str[24];
    snprintf(id_str, sizeof(id_str), "%lld", (long long)task_id);
    const char *params[2] = { id_str, err_msg };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "icr_task_fail: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

int icr_task_list_json(IcrDb *db, int limit, char *out, size_t out_size) {
    const char *sql =
        "SELECT json_agg(t) FROM ("
        "  SELECT id, kind, state, exit_code,"
        "    to_char(created_at,'YYYY-MM-DD\"T\"HH24:MI:SSZ') AS created_at,"
        "    to_char(completed_at,'YYYY-MM-DD\"T\"HH24:MI:SSZ') AS completed_at"
        "  FROM tasks ORDER BY created_at DESC LIMIT $1"
        ") t";
    char lim_str[12];
    snprintf(lim_str, sizeof(lim_str), "%d", limit);
    const char *params[1] = { lim_str };
    PGresult *res = PQexecParams(db->conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "icr_task_list_json: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        snprintf(out, out_size, "[]");
        return -1;
    }
    const char *json = PQgetvalue(res, 0, 0);
    if (!json || PQgetisnull(res, 0, 0)) {
        snprintf(out, out_size, "[]");
    } else {
        snprintf(out, out_size, "%s", json);
    }
    PQclear(res);
    return 0;
}

/* ── Project management ──────────────────────────────────────────────────────── */

int64_t icr_project_get_or_create(IcrDb *db, const char *name,
                                   const char *root_path) {
    /* Try SELECT first */
    const char *sel = "SELECT id FROM icarium_projects WHERE name=$1";
    const char *sel_params[1] = { name };
    PGresult *res = PQexecParams(db->conn, sel, 1, NULL, sel_params, NULL, NULL, 0);
    if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) > 0) {
        int64_t id = atoll(PQgetvalue(res, 0, 0));
        PQclear(res);
        return id;
    }
    PQclear(res);

    /* INSERT ... ON CONFLICT DO NOTHING RETURNING id */
    const char *ins =
        "INSERT INTO icarium_projects(name, root_path) VALUES($1,$2)"
        " ON CONFLICT(name) DO UPDATE SET root_path=EXCLUDED.root_path RETURNING id";
    const char *ins_params[2] = { name, root_path };
    res = PQexecParams(db->conn, ins, 2, NULL, ins_params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "icr_project_get_or_create: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        return -1;
    }
    int64_t id = atoll(PQgetvalue(res, 0, 0));
    PQclear(res);
    return id;
}

/* ── Entity management ───────────────────────────────────────────────────────── */

int icr_entity_insert(IcrDb *db, int64_t project_id, const char *kind,
                      const char *name, const char *file_path,
                      int line_start, int line_end, float confidence,
                      int64_t *entity_id_out) {
    const char *sql =
        "INSERT INTO entities(project_id, kind, name, file_path, line_start, line_end, confidence)"
        " VALUES($1,$2,$3,$4,$5,$6,$7)"
        " ON CONFLICT DO NOTHING RETURNING id";
    char proj_str[24], ls_str[12], le_str[12], conf_str[16];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    snprintf(ls_str,   sizeof(ls_str),   "%d",   line_start);
    snprintf(le_str,   sizeof(le_str),   "%d",   line_end);
    snprintf(conf_str, sizeof(conf_str), "%.4f", (double)confidence);
    const char *params[7] = { proj_str, kind, name, file_path, ls_str, le_str, conf_str };
    PGresult *res = PQexecParams(db->conn, sql, 7, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "icr_entity_insert: %s\n", PQerrorMessage(db->conn));
        PQclear(res);
        return -1;
    }
    if (entity_id_out) {
        *entity_id_out = (PQntuples(res) > 0) ? atoll(PQgetvalue(res, 0, 0)) : 0;
    }
    PQclear(res);
    return 0;
}

int icr_entities_delete_file(IcrDb *db, int64_t project_id,
                              const char *file_path) {
    const char *sql = "DELETE FROM entities WHERE project_id=$1 AND file_path=$2";
    char proj_str[24];
    snprintf(proj_str, sizeof(proj_str), "%lld", (long long)project_id);
    const char *params[2] = { proj_str, file_path };
    PGresult *res = PQexecParams(db->conn, sql, 2, NULL, params, NULL, NULL, 0);
    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK);
    if (!ok) fprintf(stderr, "icr_entities_delete_file: %s\n", PQerrorMessage(db->conn));
    PQclear(res);
    return ok ? 0 : -1;
}

/* ── Shell execution ─────────────────────────────────────────────────────────── */

int icr_exec_shell(const char *cmd, char *stdout_out, size_t out_size,
                   int *exit_code_out) {
    FILE *fp = popen(cmd, "r");
    if (!fp) {
        *exit_code_out = -1;
        if (out_size > 0) stdout_out[0] = '\0';
        return -1;
    }
    size_t n = fread(stdout_out, 1, out_size - 1, fp);
    stdout_out[n] = '\0';
    int status = pclose(fp);
    *exit_code_out = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return 0;
}
