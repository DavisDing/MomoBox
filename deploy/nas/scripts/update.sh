#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
NAS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=$NAS_DIR/compose.yaml
BACKUP=$SCRIPT_DIR/backup.sh
LOCK_HELPER=$SCRIPT_DIR/deployment-lock.sh
SKIP_BACKUP=0
BACKEND_STOPPED=0

usage() {
    cat <<USAGE
Usage: $PROGRAM [--skip-backup]

Safely update momo-backend from the pinned image configured by
MOMO_BACKEND_IMAGE in:
  $NAS_DIR/.env

The default flow is:
  1. Acquire the deployment lock and create/validate a PostgreSQL backup.
  2. Pull the configured, traceable backend image.
  3. Stop the currently running backend before schema migration.
  4. Run momo-backend migrate against PostgreSQL.
  5. Start momo-backend and wait for its Docker healthcheck to become healthy.

Options:
  --skip-backup  Skip the backup step. Use only when a current, verified backup
                 already exists outside this NAS deployment directory.
  -h, --help     Show this help and exit

If migration or the post-update healthcheck fails after the old backend is
stopped, this script leaves the backend stopped/failed rather than claiming a
successful deployment. The backup path is printed before the update proceeds.
USAGE
}

fail() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --skip-backup)
            SKIP_BACKUP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            [ "$#" -eq 0 ] || fail "unexpected argument: $1"
            ;;
        -* )
            fail "unknown option: $1"
            ;;
        *)
            fail "unexpected argument: $1"
            ;;
    esac
done

[ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
[ -f "$BACKUP" ] || fail "backup script not found: $BACKUP"
[ -x "$BACKUP" ] || fail "backup script is not executable: $BACKUP"
[ -f "$LOCK_HELPER" ] || fail "deployment lock helper not found: $LOCK_HELPER"
# shellcheck disable=SC1090
. "$LOCK_HELPER"

momo_deployment_lock_acquire || exit 1
cleanup() {
    status=$?
    momo_deployment_lock_release
    trap - 0 HUP INT TERM
    exit "$status"
}
trap cleanup 0
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
command -v docker >/dev/null 2>&1 || fail "docker is required for service health inspection"

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

wait_for_service_health() {
    service=$1
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        container_id=$(compose ps -q "$service" 2>/dev/null | tail -n 1)
        if [ -n "$container_id" ]; then
            health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
                "$container_id" 2>/dev/null || printf 'missing')
            case "$health" in
                healthy)
                    return 0
                    ;;
                unhealthy|no-healthcheck|missing)
                    if [ "$health" = unhealthy ] || [ "$health" = no-healthcheck ]; then
                        return 1
                    fi
                    ;;
            esac
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

if [ "$SKIP_BACKUP" -eq 0 ]; then
    BACKUP_PATH=$($BACKUP) || fail "backup failed; no image was pulled or service was stopped"
    printf '%s\n' "Backup created: $BACKUP_PATH"
else
    printf '%s\n' 'WARNING: skipping backup at caller request.' >&2
fi

# Pull before stopping a healthy service so registry failures do not create
# downtime. The image is pinned by MOMO_BACKEND_IMAGE in the NAS .env file.
compose pull momo-backend || fail "failed to pull momo-backend; current service was left unchanged"

if compose ps --status running --services 2>/dev/null | grep -Fx 'momo-backend' >/dev/null 2>&1; then
    compose stop momo-backend >/dev/null || fail "failed to stop momo-backend before migration"
    BACKEND_STOPPED=1
fi

compose up -d postgres >/dev/null
wait_for_postgres || fail "postgres did not become ready within 60 seconds"

if ! compose run --rm momo-backend migrate; then
    if [ "$BACKEND_STOPPED" -eq 1 ]; then
        printf '%s: migration failed; momo-backend remains stopped to avoid running against an unverified schema.\n' "$PROGRAM" >&2
    fi
    exit 1
fi

compose up -d momo-backend >/dev/null
if ! wait_for_service_health momo-backend; then
    printf '%s: momo-backend did not become healthy within 60 seconds; inspect compose logs before retrying.\n' "$PROGRAM" >&2
    exit 1
fi

printf '%s\n' 'MomoBox backend update completed successfully and passed its healthcheck.'
