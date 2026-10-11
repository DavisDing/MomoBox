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

usage() {
    cat <<USAGE
Usage: $PROGRAM [--yes] DUMP_FILE

Restore a PostgreSQL custom-format dump into the database configured for the
postgres service in:
  $COMPOSE_FILE

Options:
  -y, --yes   Skip the interactive confirmation (for deliberate automation)
  -h, --help  Show this help and exit

Safety behavior:
  * No dump path means no action and a non-zero exit.
  * The dump is validated before any service is stopped or database is changed.
  * Every backend instance in this project is stopped and verified before writes.
  * The backend stays stopped on success, failure, or interruption. A restored
    database is NOT automatically safe for existing App sync cursors/sessions.
  * Objects represented by the dump are cleaned and restored in one transaction.
    Active sessions are terminated after momo-backend is stopped.
USAGE
}

fail() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case $1 in
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
    momo_deployment_lock_release
    trap - 0 HUP INT TERM
    exit "$status"
}
trap cleanup_lock 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_KIND=docker
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_KIND=docker-compose
else
    fail "Docker Compose is required (docker compose or docker-compose)"
fi
command -v docker >/dev/null 2>&1 || fail "docker is required to verify backend isolation"

compose() {
    if [ "$COMPOSE_KIND" = docker ]; then
        docker compose --project-directory "$NAS_DIR" -f "$COMPOSE_FILE" "$@"
    else
        docker-compose --project-directory "$NAS_DIR" -f "$COMPOSE_FILE" "$@"
    fi
}

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
compose up -d postgres >/dev/null
wait_for_postgres || fail "postgres did not become ready within 60 seconds"
if ! compose exec -T postgres pg_restore --list <"$DUMP_FILE" >/dev/null; then
    fail "the file is not a readable PostgreSQL custom-format dump"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf '%s\n' "WARNING: this will replace the configured MomoBox PostgreSQL database." >&2
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

momo_backend_verify_stopped || fail "backend became active during restore"
compose run --rm --no-deps momo-backend schema-check || fail "restored schema does not match the configured image; backend remains stopped"
printf '%s\n' "Database restore and read-only schema check completed. Backend remains stopped; this is not deployment approval."
