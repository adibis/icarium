#!/usr/bin/env bash
# Mechanical pre-commit checks. Run before every git commit.
#
# Usage:
#   scripts/precommit-check.sh         # default: staged diff + COMMIT_EDITMSG
#   scripts/precommit-check.sh staged  # explicit
#   scripts/precommit-check.sh head    # post-hoc check against HEAD
#
# Exit codes: 0 = pass, 1 = FAIL (do not commit), 2 = usage error.
#
# Scans added lines for internal references, checks the
# commit message against the repo's message rules, then requires a green
# build, unit tests, and (when yosys exists) the e2e suite. Design
# review stays manual; this script only covers the mechanical.

set -euo pipefail

mode="${1:-staged}"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

errors=0
warnings=0
fail() { red    "FAIL: $*"; errors=$((errors + 1)); }
warn() { yellow "WARN: $*"; warnings=$((warnings + 1)); }
pass() { green  "PASS: $*"; }

# Only code and its tests are scanned: docs legitimately name roadmap
# phases. The self-exclusion is load-bearing, not defensive — the
# TODO pattern below would otherwise match its own source line.
self_exclude=':(exclude)scripts/precommit-check.sh'

case "$mode" in
    staged)
        diff_content="$(git diff --cached --unified=0 -- src tests scripts "$self_exclude")"
        if [[ -f .git/COMMIT_EDITMSG ]]; then
            msg_content="$(cat .git/COMMIT_EDITMSG)"
        else
            msg_content=""
        fi
        ;;
    head)
        diff_content="$(git show HEAD --unified=0 -- src tests scripts "$self_exclude")"
        msg_content="$(git log -1 --format=%B HEAD)"
        ;;
    *)
        echo "Usage: $0 [staged|head]" >&2
        exit 2
        ;;
esac

# Lines added in this diff (drop +++ header lines)
added_lines="$(printf '%s\n' "$diff_content" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"

# --- 1. Forbidden patterns in added lines ----------------------------------

check_fail_in_diff() {
    local pattern="$1"
    local label="$2"
    local hits
    hits="$(printf '%s\n' "$added_lines" | grep -nE "$pattern" || true)"
    if [[ -n "$hits" ]]; then
        fail "$label"
        printf '%s\n' "$hits" | sed 's/^/    /'
    fi
}

check_warn_in_diff() {
    local pattern="$1"
    local label="$2"
    local hits
    hits="$(printf '%s\n' "$added_lines" | grep -niE "$pattern" || true)"
    if [[ -n "$hits" ]]; then
        warn "$label"
        printf '%s\n' "$hits" | sed 's/^/    /'
    fi
}

check_fail_in_diff '(^|[^A-Za-z])(Phase|phase)[[:space:]]+[0-9]+'   'Phase reference'
check_fail_in_diff '(^|[^A-Za-z])(Chunk|chunk)[[:space:]]+[0-9]+'   'Chunk reference'
check_fail_in_diff '(^|[^A-Za-z])(Sprint|sprint)[[:space:]]+[0-9]+' 'Sprint reference'
check_fail_in_diff '(TODO|FIXME|XXX|HACK)'                          'TODO/FIXME/XXX/HACK marker'
check_fail_in_diff '(as discussed|as decided)' 'Conversation reference'

check_warn_in_diff '(for now|in the future|to be added|going to be)' 'Forward-looking phrasing (judge case-by-case)'
check_warn_in_diff '(later this|will be added|will land)'           'Forward-looking phrasing (judge case-by-case)'

# --- 2. Commit message checks ----------------------------------------------

if [[ -n "$msg_content" ]]; then
    subject="$(printf '%s\n' "$msg_content" | head -n 1)"

    if printf '%s\n' "$subject" | grep -qE '^(feat|fix|docs|chore|refactor|test|style|perf|ci|build)(\([^)]*\))?:[[:space:]]'; then
        fail "Conventional-commit prefix in subject: $subject"
    fi

    if printf '%s\n' "$msg_content" | grep -qE '(^|[^A-Za-z])(Phase|phase|Chunk|chunk)[[:space:]]+[0-9]+'; then
        fail "Internal reference in commit message"
        printf '%s\n' "$msg_content" | grep -nE '(^|[^A-Za-z])(Phase|phase|Chunk|chunk)[[:space:]]+[0-9]+' | sed 's/^/    /'
    fi

    if printf '%s\n' "$msg_content" | grep -qE '(as discussed|as decided)'; then
        fail "Conversation reference in commit message"
    fi

    if printf '%s\n' "$msg_content" | grep -qiE 'co-authored-by:'; then
        fail "Attribution trailer in commit message"
    fi
fi

# --- 3. Build green --------------------------------------------------------

if zig build test >/tmp/precommit-test.log 2>&1; then
    pass "zig build test (unit tests)"
else
    fail "zig build test (unit tests) — see /tmp/precommit-test.log"
    tail -20 /tmp/precommit-test.log | sed 's/^/    /'
fi

if zig build >/tmp/precommit-build.log 2>&1; then
    pass "zig build"
else
    fail "zig build — see /tmp/precommit-build.log"
    tail -10 /tmp/precommit-build.log | sed 's/^/    /'
fi

# The e2e suite needs yosys; without it there is nothing to run,
# but a present-and-failing suite blocks the commit like the rest.
set +e
sh tests/e2e/run.sh >/tmp/precommit-e2e.log 2>&1
e2e_code=$?
set -e
if [[ $e2e_code -eq 0 ]]; then
    pass "e2e suite"
elif [[ $e2e_code -eq 3 ]]; then
    warn "e2e skipped (yosys not on PATH)"
else
    fail "e2e suite — see /tmp/precommit-e2e.log"
    grep -E 'FAIL' /tmp/precommit-e2e.log | sed 's/^/    /'
fi

# Snapshots pin generated CLI text: help and the rules reference
# drift only by deliberate regeneration, never by accident.
set +e
./zig-out/bin/icarium --help > /tmp/precommit-help.txt 2>&1
help_code=$?
./zig-out/bin/icarium rules --doc > /tmp/precommit-rules-doc.txt 2>&1
doc_code=$?
set -e
if [[ $help_code -ne 0 ]] || ! cmp -s /tmp/precommit-help.txt tests/snapshots/help.txt; then
    fail "help snapshot drift — regenerate tests/snapshots/help.txt"
else
    pass "help snapshot"
fi
if [[ $doc_code -ne 0 ]] || ! cmp -s /tmp/precommit-rules-doc.txt tests/snapshots/rules-doc.txt; then
    fail "rules-doc snapshot drift — regenerate tests/snapshots/rules-doc.txt"
else
    pass "rules-doc snapshot"
fi

# Rule fixtures need yosys like e2e; same safe-skip contract.
set +e
sh fixtures/run.sh >/tmp/precommit-fixtures.log 2>&1
fx_code=$?
set -e
if [[ $fx_code -eq 0 ]]; then
    pass "rule fixtures"
elif [[ $fx_code -eq 3 ]]; then
    warn "rule fixtures skipped (yosys not on PATH)"
else
    fail "rule fixtures — see /tmp/precommit-fixtures.log"
    grep -E 'FAIL' /tmp/precommit-fixtures.log | sed 's/^/    /'
fi

# Native JSON artifacts validate against schema/; same safe-skip
# contract as the yosys-backed suites above.
set +e
sh scripts/validate-schemas.sh >/tmp/precommit-schemas.log 2>&1
sc_code=$?
set -e
if [[ $sc_code -eq 0 ]]; then
    pass "schema validation"
elif [[ $sc_code -eq 3 ]]; then
    warn "schema validation skipped (yosys/python3/jsonschema missing)"
else
    fail "schema validation — see /tmp/precommit-schemas.log"
    grep -E 'FAIL' /tmp/precommit-schemas.log | sed 's/^/    /'
fi

# Suppression CLI suite; same safe-skip contract.
set +e
sh tests/suppress/run.sh >/tmp/precommit-suppress.log 2>&1
sp_code=$?
set -e
if [[ $sp_code -eq 0 ]]; then
    pass "suppression suite"
elif [[ $sp_code -eq 3 ]]; then
    warn "suppression suite skipped (yosys/python3/jsonschema missing)"
else
    fail "suppression suite — see /tmp/precommit-suppress.log"
    grep -E 'FAIL' /tmp/precommit-suppress.log | sed 's/^/    /'
fi

# --- Summary ---------------------------------------------------------------

echo
if (( errors > 0 )); then
    red "$errors FAIL, $warnings WARN — do not commit"
    exit 1
fi
if (( warnings > 0 )); then
    yellow "$warnings WARN — review the lines above before committing"
fi
green "All checks passed"
