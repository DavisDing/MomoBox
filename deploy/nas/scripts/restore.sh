#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
NAS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=$NAS_DIR/compose.yaml
ASSUME_YES=0
DUMP_FILE=
BACKEND_WAS_RUNNING=0
BACKEND_STOPPED=0

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
  * If momo-backend is running, it is stopped during restore and started again
    on both success and failure.
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
[ -f "$DUMP_FILE" ] || fail "dump file not found: $DUMP_FILE"
[ -r "$DUMP_FILE" ] || fail "dump file is not readable: $DUMP_FILE"
[ -s "$DUMP_FILE" ] || fail "dump file is empty: $DUMP_FILE"

# Resolve before changing services, and before a caller can change cwd context.
DUMP_DIR=$(CDPATH= cd -P "$(dirname "$DUMP_FILE")" && pwd) || fail "cannot resolve dump directory"
DUMP_FILE=$DUMP_DIR/$(basename "$DUMP_FILE")

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_KIND=docker
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_KIND=docker-compose
else
    fail "Docker Compose is required (docker compose or docker-compose)"
fi

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
        if compose exec -T postgres sh -eu -c             'exec pg_isready --quiet --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'             >/dev/null 2>&1; then
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

# Record the original backend state. Only restart a service that this script
# actually stopped; a deliberately stopped backend remains stopped.
if compose ps --status running --services 2>/dev/null | grep -Fx 'momo-backend' >/dev/null 2>&1; then
    BACKEND_WAS_RUNNING=1
fi

restart_backend() {
    status=$?
    trap - 0 HUP INT TERM
    if [ "$BACKEND_STOPPED" -eq 1 ] && [ "$BACKEND_WAS_RUNNING" -eq 1 ]; then
        if ! compose start momo-backend >/dev/null; then
            printf '%s: warning: failed to restart momo-backend\n' "$PROGRAM" >&2
            [ "$status" -ne 0 ] || status=1
        fi
    fi
    exit "$status"
}
trap restart_backend 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$BACKEND_WAS_RUNNING" -eq 1 ]; then
    compose stop momo-backend >/dev/null || fail "failed to stop momo-backend"
    BACKEND_STOPPED=1
fi

# With momo-backend stopped, terminate any remaining sessions to prevent stale
# application connections from interfering. current_database() avoids embedding
# the configured database name in SQL or output.
if ! compose exec -T postgres sh -eu -c '
    exec psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      --set=ON_ERROR_STOP=1 --tuples-only --no-align \
      --command="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();"
' >/dev/null; then
    fail "failed to terminate active target-database sessions"
fi

# --single-transaction prevents a partially applied logical restore.
if ! compose exec -T postgres sh -eu -c '
    exec pg_restore --clean --if-exists --exit-on-error --single-transaction \
      --no-owner --no-privileges --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"
' <"$DUMP_FILE"; then
    fail "database restore failed"
fi

printf '%s\n' "Restore completed successfully."
