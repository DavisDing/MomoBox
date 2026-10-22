#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
NAS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=$NAS_DIR/docker-compose.yaml
LOCK_HELPER=$SCRIPT_DIR/deployment-lock.sh
ISOLATION_HELPER=$SCRIPT_DIR/backend-isolation.sh
ASSUME_YES=0
DUMP_FILE=
DATABASE_TASK_UNCERTAIN=0
PROOF_OUTPUT=
SOURCE_META=
SOURCE_RECORD=

usage() {
    cat <<USAGE
Usage: $PROGRAM [--yes] [shared identity options] [--proof-output FILE] DUMP_FILE

Without shared options, restore the original PG16 database configured in:
  $COMPOSE_FILE

Options:
  -y, --yes   Skip the interactive confirmation (for deliberate automation)
  --proof-output FILE  New local proof file, required for managed/external mode
  -h, --help  Show this help and exit

Safety behavior:
  * No dump path means no action and a non-zero exit.
  * The dump is validated before any service is stopped or database is changed.
  * Every backend instance in this project is stopped and verified before writes.
  * The backend stays stopped on success, failure, or interruption. A restored
    database is NOT automatically safe for existing App sync cursors/sessions.
  * Original mode cleans represented objects and terminates target sessions.
  * Managed/external mode requires an empty, precreated candidate database whose
    name differs from the source. It never cleans objects or terminates sessions.
  * Candidate proof records archive and ledger checks, not full DR approval.
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
        --proof-output)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$PROOF_OUTPUT" ] || fail "--proof-output requires one new output file"
            PROOF_OUTPUT=$2
            shift 2 ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                [ -z "$DUMP_FILE" ] || fail "only one dump file may be specified"
                DUMP_FILE=$1
                shift
            done
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            [ -z "$DUMP_FILE" ] || fail "only one dump file may be specified"
            DUMP_FILE=$1
            shift
            ;;
    esac
done

[ -n "$DUMP_FILE" ] || {
    usage >&2
    fail "a dump file is required"
}
momo_context_init
[ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
[ -f "$LOCK_HELPER" ] || fail "deployment lock helper not found: $LOCK_HELPER"
[ -f "$ISOLATION_HELPER" ] || fail "backend isolation helper not found: $ISOLATION_HELPER"
[ -f "$DUMP_FILE" ] || fail "dump file not found: $DUMP_FILE"
[ -r "$DUMP_FILE" ] || fail "dump file is not readable: $DUMP_FILE"
[ -s "$DUMP_FILE" ] || fail "dump file is empty: $DUMP_FILE"

# Resolve before changing services, and before a caller can change cwd context.
DUMP_DIR=$(CDPATH= cd -P "$(dirname "$DUMP_FILE")" && pwd) || fail "cannot resolve dump directory"
DUMP_FILE=$DUMP_DIR/$(basename "$DUMP_FILE")

# Acquire the same lock used by update.sh and backup.sh before touching the
# Compose project or database. A restore never runs concurrently with backup
# or update.
# shellcheck disable=SC1090
. "$LOCK_HELPER"
. "$ISOLATION_HELPER"
momo_deployment_lock_acquire || exit 1
cleanup_lock() {
    status=$?
    if [ "$MOMO_DATABASE_MODE" != legacy ] && ! momo_client_tasks_quiescent; then
        printf '%s: PostgreSQL client task completion is unknown; deployment lock retained.\n' "$PROGRAM" >&2
        exit 1
    fi
    momo_deployment_lock_release
    trap - 0 HUP INT TERM
    exit "$status"
}
trap cleanup_lock 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_postgres() {
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        if compose exec -T postgres sh -eu -c \
            'exec pg_isready --quiet --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' \
            >/dev/null 2>&1; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

# Start only PostgreSQL so validation can use the image-matched pg_restore.
momo_database_ready
if ! momo_dump_list <"$DUMP_FILE"; then
    fail "the file is not a readable PostgreSQL custom-format dump"
fi

if [ "$MOMO_DATABASE_MODE" != legacy ]; then
    SOURCE_META=$DUMP_FILE.meta
    # Snapshot a strict whitelist before changing the candidate. Never copy
    # arbitrary metadata fields into a proof or source metadata as shell code.
    for source_key in format database role pg_major server_address database_oid client_image schema_signature sha256; do
        source_value=$(momo_meta_get "$SOURCE_META" "$source_key") || fail "source metadata field missing or duplicated: $source_key"
        SOURCE_RECORD="${SOURCE_RECORD}${source_key}=${source_value}
"
    done
    source_cluster=$(momo_meta_get "$SOURCE_META" cluster || true)
    if [ -n "$source_cluster" ]; then SOURCE_RECORD="${SOURCE_RECORD}cluster=${source_cluster}
"; fi
    SOURCE_META_SHA=$(momo_sha256 "$SOURCE_META") || fail "cannot fingerprint source metadata"
    SOURCE_DUMP_SHA=$(momo_sha256 "$DUMP_FILE") || fail "cannot fingerprint source dump"
    [ "$(momo_meta_get "$SOURCE_META" format)" = 1 ] || fail "candidate restore requires source backup metadata"
    [ "$(momo_meta_get "$SOURCE_META" sha256)" = "$SOURCE_DUMP_SHA" ] || fail "source dump checksum mismatch"
    [ "$(momo_meta_get "$SOURCE_META" database)" != "$MOMO_EXPECTED_DATABASE" ] || fail "candidate database must differ from source"
    [ "$(momo_meta_get "$SOURCE_META" pg_major)" = "$(printf "%s\n" "$momo_identity" | sed -n "s/^pg_major=//p")" ] || fail "candidate PostgreSQL major differs"
    [ "$(momo_meta_get "$SOURCE_META" client_image)" = "$MOMO_PG_CLIENT_IMAGE" ] || fail "candidate client image differs from backup"
    [ -n "$PROOF_OUTPUT" ] && [ ! -e "$PROOF_OUTPUT" ] || fail "a new --proof-output file is required"
    momo_pg empty || fail "candidate must be empty with no other clients"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ "$MOMO_DATABASE_MODE" = legacy ]; then
        printf '%s\n' "WARNING: this will replace the configured MomoBox PostgreSQL database." >&2
    else
        printf '%s\n' "Restore only into the selected empty candidate; it will remain quarantined." >&2
    fi
    printf '%s\n' "Dump: $DUMP_FILE" >&2
    printf '%s' "Type RESTORE to continue: " >&2
    IFS= read -r CONFIRMATION || fail "confirmation input was not received"
    [ "$CONFIRMATION" = RESTORE ] || fail "restore cancelled"
fi

restore_cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    if ! momo_backend_stop_verified || ! momo_deployment_tasks_quiescent; then
        printf '%s: isolation unverified; lock retained. Inspect active restore tasks before manual recovery.\n' "$PROGRAM" >&2
        exit 1
    fi
    if [ "$DATABASE_TASK_UNCERTAIN" -eq 1 ]; then
        printf '%s: database task completion is unknown; lock retained, verify PostgreSQL activity before manual recovery.\n' "$PROGRAM" >&2
        exit 1
    fi
    printf '%s: backend remains stopped; restore history, sessions, and App offline intents require separate validation.\n' "$PROGRAM" >&2
    momo_deployment_lock_release
    exit "$status"
}
# Do not use EXIT or a successful pg_restore as permission to reopen service.
trap restore_cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

momo_backend_stop_verified || fail "failed to stop and verify momo-backend"
(umask 077; printf "%s\n" "Restored history: do not start without separate DR approval" >"$NAS_DIR/.momobox-restored") || fail "cannot quarantine restored deployment"

if [ "$MOMO_DATABASE_MODE" = legacy ]; then
# With momo-backend stopped, terminate any remaining sessions to prevent stale
# application connections from interfering. current_database() avoids embedding
# the configured database name in SQL or output.
DATABASE_TASK_UNCERTAIN=1
if compose exec -T postgres sh -eu -c '
    exec psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      --set=ON_ERROR_STOP=1 --tuples-only --no-align \
      --command="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();"
' >/dev/null; then
    DATABASE_TASK_UNCERTAIN=0
else
    fail "failed to terminate active target-database sessions"
fi

# --single-transaction prevents a partially applied logical restore.
DATABASE_TASK_UNCERTAIN=1
if compose exec -T postgres sh -eu -c '
    exec pg_restore --clean --if-exists --exit-on-error --single-transaction \
      --no-owner --no-privileges --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"
' <"$DUMP_FILE"; then
    DATABASE_TASK_UNCERTAIN=0
else
    fail "database restore failed"
fi

else
    DATABASE_TASK_UNCERTAIN=1
    if momo_pg restore-candidate <"$DUMP_FILE"; then DATABASE_TASK_UNCERTAIN=0
    else fail "candidate restore failed; backend remains quarantined"; fi
fi

momo_backend_verify_stopped || fail "backend became active during restore"
compose run --rm --no-deps momo-backend schema-check || fail "restored schema does not match the configured image; backend remains stopped"
if [ "$MOMO_DATABASE_MODE" != legacy ]; then
    [ "$(momo_sha256 "$DUMP_FILE")" = "$SOURCE_DUMP_SHA" ] &&
        [ "$(momo_sha256 "$SOURCE_META")" = "$SOURCE_META_SHA" ] || fail "source dump or metadata changed; no proof created"
    proof_dir=$(CDPATH= cd -P "$(dirname "$PROOF_OUTPUT")" && pwd) || fail "proof directory missing"
    proof_tmp=$(mktemp "$proof_dir/.momobox-proof.XXXXXX") || fail "cannot create proof"
    chmod 600 "$proof_tmp"
    { printf '%s' "$SOURCE_RECORD"; printf "verified=candidate-schema-check\nverified_at=%s\ncandidate_database=%s\n" "$(date -u +%s)" "$MOMO_EXPECTED_DATABASE"; } >"$proof_tmp"
    # noclobber prevents an existing proof from being overwritten.
    (set -C; cat "$proof_tmp" >"$PROOF_OUTPUT") || { rm -f "$proof_tmp"; fail "cannot finalize proof"; }
    chmod 600 "$PROOF_OUTPUT"
    rm -f "$proof_tmp"
fi
printf '%s\n' "Database restore and read-only schema check completed. Backend remains stopped; this is not deployment approval."
