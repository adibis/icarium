#pragma once
#include <stddef.h>

/*
 * Plugin record validation — enforces schema/plugin_schema.json and the
 * partition/kind consistency rules from ONTOLOGY.md §7.3.
 *
 * Called by the daemon for every line of plugin stdout before DB insertion.
 * Zero external dependencies — pure libc string scanning.
 */

typedef enum {
    ICR_RECORD_ENTITY   = 1,
    ICR_RECORD_RELATION = 2,
} IcrRecordType;

typedef struct {
    char         message[256]; /* human-readable reason */
    IcrRecordType record_type; /* 0 if type could not be determined */
    int          line_no;      /* 1-based line number within plugin stream */
} IcrValidateError;

/*
 * Validate one newline-delimited JSON record emitted by a plugin.
 *
 * line     - null-terminated JSON string (trailing newline stripped by caller)
 * line_no  - 1-based position in plugin stdout stream (for error messages)
 * err      - populated on failure; may be NULL if caller only needs pass/fail
 *
 * Returns 0 on success, -1 on validation error.
 */
int icr_validate_record(const char *line, int line_no, IcrValidateError *err);

/*
 * Convenience wrapper: validate every newline-terminated line in buf[0..len].
 * Calls cb(err, userdata) for each invalid line. Returns count of failures.
 */
typedef void (*IcrValidateCb)(const IcrValidateError *err, void *userdata);
int icr_validate_stream(const char *buf, size_t len,
                        IcrValidateCb cb, void *userdata);
