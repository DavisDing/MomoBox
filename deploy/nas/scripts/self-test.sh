#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
BACKUP=$SCRIPT_DIR/backup.sh
RESTORE=$SCRIPT_DIR/restore.sh
TMP_DIR=${TMPDIR:-/tmp}/momobox-nas-script-test-$$

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$TMP_DIR"

fail() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

for script in "$BACKUP" "$RESTORE" "$0"; do
    sh -n "$script" || fail "syntax check failed: $script"
done

# Invoke from an unrelated working directory to exercise location-independent
# help paths without requiring Docker or a running database.
(
    cd "$TMP_DIR"
    "$BACKUP" --help >backup-help.txt
    "$RESTORE" --help >restore-help.txt
    grep -q '^Usage:' backup-help.txt
    grep -q '^Usage:' restore-help.txt
) || fail "help behavior test failed"

if "$RESTORE" >"$TMP_DIR/restore-no-arg.out" 2>"$TMP_DIR/restore-no-arg.err"; then
    fail "restore without a dump unexpectedly succeeded"
fi
grep -q 'a dump file is required' "$TMP_DIR/restore-no-arg.err" || fail "restore no-argument error was not descriptive"

if "$BACKUP" --not-a-real-option >"$TMP_DIR/backup-unknown.out" 2>"$TMP_DIR/backup-unknown.err"; then
    fail "backup with an unknown option unexpectedly succeeded"
fi
grep -q 'unknown option' "$TMP_DIR/backup-unknown.err" || fail "backup unknown-option error was not descriptive"

printf '%s\n' "All shell syntax and help/argument behavior checks passed."
