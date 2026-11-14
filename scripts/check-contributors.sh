#!/bin/sh
# Fail when a commit in RANGE has an author who has not signed CONTRIBUTORS.
# Usage: check-contributors.sh BASE..HEAD
set -eu
range=${1:?usage: check-contributors.sh BASE..HEAD}
signed=$(grep -v '^#' CONTRIBUTORS | sed '/^[[:space:]]*$/d')
missing=0
authors=$(git log --format='%an' "$range" | sort -u)
IFS='
'
for name in $authors; do
    case "$name" in *'[bot]') continue ;; esac
    if ! printf '%s\n' "$signed" | grep -qxF "$name"; then
        echo "not in CONTRIBUTORS: $name"
        missing=1
    fi
done
[ "$missing" -eq 0 ] && echo "every author has signed CONTRIBUTORS"
exit "$missing"
