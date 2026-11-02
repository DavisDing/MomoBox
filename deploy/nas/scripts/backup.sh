#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
NAS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=$NAS_DIR/docker-compose.yaml
LOCK_HELPER=$SCRIPT_DIR/deployment-lock.sh
DEFAULT_OUTPUT_DIR=$NAS_DIR/backups
OUTPUT_DIR=$DEFAULT_OUTPUT_DIR
OUTPUT_DIR_SET=0
RETAIN_COUNT=30

usage() {
    cat <<USAGE
Usage: $PROGRAM [--output-dir DIR] [--retain-count N]

Create a PostgreSQL custom-format backup using the postgres service in:
  $COMPOSE_FILE

Options:
  -o, --output-dir DIR  Destination directory (default: $DEFAULT_OUTPUT_DIR)
  --retain-count N      Keep newest N unpinned completed backups (default: 30).
                        0 disables pruning. A .dump.keep file pins a backup.
  -h, --help            Show this help and exit

The completed dump path is printed to standard output. The dump is written to a
private temporary file, validated with pg_restore --list, and atomically renamed.
USAGE
    momo_context_help
}

fail() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

. "$SCRIPT_DIR/deployment-context.sh"
. "$SCRIPT_DIR/postgres-client.sh"

while [ "$#" -gt 0 ]; do
    momo_context_option "$@"
    if [ "$MOMO_OPTION_CONSUMED" -gt 0 ]; then shift "$MOMO_OPTION_CONSUMED"; continue; fi
    case $1 in
        -o|--output-dir)
            [ "$#" -ge 2 ] || fail "$1 requires a directory argument"
            [ -n "$2" ] || fail "$1 requires a non-empty directory argument"
            OUTPUT_DIR=$2
            OUTPUT_DIR_SET=1
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --retain-count)
            [ "$#" -ge 2 ] || fail "$1 requires a count"
            case "$2" in ''|*[!0-9]*|0[0-9]*) fail "retain-count must be a non-negative integer" ;; esac
            [ "${#2}" -le 6 ] || fail "retain-count is too large"
            RETAIN_COUNT=$2
            shift 2
            ;;
        --)
            shift
            [ "$#" -eq 0 ] || fail "unexpected argument: $1"
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            fail "unexpected argument: $1"
            ;;
    esac
done

momo_context_init
if [ "$OUTPUT_DIR_SET" -eq 0 ]; then OUTPUT_DIR=$NAS_DIR/backups; fi
[ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
[ -f "$LOCK_HELPER" ] || fail "deployment lock helper not found: $LOCK_HELPER"
# shellcheck disable=SC1090
. "$LOCK_HELPER"

momo_deployment_lock_acquire || exit 1
cleanup_lock() {
    status=$?
    momo_deployment_lock_release
    trap - 0 HUP INT TERM
    exit "$status"
}
trap cleanup_lock 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"
command -v date >/dev/null 2>&1 || fail "date is required"

wait_for_postgres() {
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        if compose exec -T postgres sh -eu -c             'exec pg_isready --quiet --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'             >/dev/null 2>&1; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

mkdir -p "$OUTPUT_DIR" || fail "cannot create output directory: $OUTPUT_DIR"
[ -d "$OUTPUT_DIR" ] || fail "output path is not a directory: $OUTPUT_DIR"
[ -w "$OUTPUT_DIR" ] || fail "output directory is not writable: $OUTPUT_DIR"

# Resolve the directory after creating it so the printed result is unambiguous.
OUTPUT_DIR=$(CDPATH= cd -P "$OUTPUT_DIR" && pwd)
TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
FINAL_PATH=$OUTPUT_DIR/momobox-postgres-$TIMESTAMP-$$.dump
TEMP_PATH=$(mktemp "$OUTPUT_DIR/.momobox-postgres.XXXXXX") || fail "cannot create temporary backup file"
chmod 600 "$TEMP_PATH" || {
    rm -f "$TEMP_PATH"
    fail "cannot secure temporary backup file"
}

cleanup_temp() {
    rm -f "$TEMP_PATH"
}
# The EXIT trap installed above releases the shared deployment lock. Keep the
# temporary dump cleanup in the same handler so both paths run exactly once.
cleanup_lock_and_temp() {
    status=$?
    cleanup_temp
    rm -f "${RETENTION_LIST:-}"
    rm -f "${TEMP_META:-}"
    if [ "$MOMO_DATABASE_MODE" != legacy ]; then
        . "$SCRIPT_DIR/backend-isolation.sh"
        momo_client_tasks_quiescent || { printf "%s\n" "client isolation unknown; lock retained" >&2; exit 1; }
    fi
    momo_deployment_lock_release
    trap - 0 HUP INT TERM
    exit "$status"
}
trap cleanup_lock_and_temp 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Start only PostgreSQL if needed. Compose reads deploy/nas/.env via
# --project-directory; credentials remain inside the container environment.
momo_database_ready

if ! momo_dump >"$TEMP_PATH"; then
    fail "pg_dump failed; no completed backup was created"
fi

[ -s "$TEMP_PATH" ] || fail "pg_dump produced an empty file"

if ! momo_dump_list <"$TEMP_PATH"; then
    fail "backup validation failed; no completed backup was created"
fi

if [ "$MOMO_DATABASE_MODE" != legacy ]; then
    TEMP_META=$(mktemp "$OUTPUT_DIR/.momobox-meta.XXXXXX") || fail "cannot create metadata"
    chmod 600 "$TEMP_META"
    momo_backup_metadata "$TEMP_PATH" >"$TEMP_META" || fail "cannot create backup metadata"
    mv "$TEMP_META" "$FINAL_PATH.meta" || fail "cannot finalize metadata"
fi

# mv is atomic because the temporary and final files are in the same directory.
[ ! -e "$FINAL_PATH" ] || fail "refusing to overwrite existing file: $FINAL_PATH"
mv "$TEMP_PATH" "$FINAL_PATH" || fail "cannot finalize backup"
RETENTION_OWNER="$NAS_DIR|$MOMO_PROJECT_NAME|$MOMO_DATABASE_MODE|$MOMO_EXPECTED_DATABASE|$MOMO_EXPECTED_ROLE"
printf '%s\n' "$RETENTION_OWNER" >"$FINAL_PATH.owner" || fail "cannot write backup retention ownership"
chmod 600 "$FINAL_PATH.owner"

# Prune only after a new archive was successfully finalized, under the same
# deployment lock. Never touch unrelated names, links, partial files or pins.
if [ "$RETAIN_COUNT" -gt 0 ]; then
    RETENTION_LIST=$(mktemp "$OUTPUT_DIR/.momobox-retention.XXXXXX") || fail "cannot create retention list"
    for candidate in "$OUTPUT_DIR"/momobox-postgres-*.dump; do
        [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
        [ "$candidate" != "$FINAL_PATH" ] || continue
        [ ! -e "$candidate.keep" ] && [ ! -L "$candidate.keep" ] || continue
        [ ! -L "$candidate.meta" ] || continue
        [ -f "$candidate.owner" ] && [ ! -L "$candidate.owner" ] || continue
        [ "$(cat "$candidate.owner")" = "$RETENTION_OWNER" ] || continue
        basename=${candidate##*/}
        if printf '%s\n' "$basename" | LC_ALL=C grep -Eq '^momobox-postgres-[0-9]{8}T[0-9]{6}Z-[0-9]+[.]dump$'; then
            printf '%s\n' "$basename"
        fi
    done | LC_ALL=C sort -r >"$RETENTION_LIST"
    count=1
    while IFS= read -r basename; do
        count=$((count + 1))
        [ "$count" -gt "$RETAIN_COUNT" ] || continue
        rm -f "$OUTPUT_DIR/$basename" "$OUTPUT_DIR/$basename.meta" "$OUTPUT_DIR/$basename.owner" || {
            rm -f "$RETENTION_LIST"
            fail "backup completed but retention cleanup failed"
        }
    done <"$RETENTION_LIST"
    rm -f "$RETENTION_LIST"
fi

printf '%s\n' "$FINAL_PATH"
