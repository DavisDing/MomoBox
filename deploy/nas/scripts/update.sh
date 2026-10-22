#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
NAS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=$NAS_DIR/docker-compose.yaml
BACKUP=$SCRIPT_DIR/backup.sh
LOCK_HELPER=$SCRIPT_DIR/deployment-lock.sh
ISOLATION_HELPER=$SCRIPT_DIR/backend-isolation.sh
SKIP_BACKUP=0
ISOLATION_REQUIRED=0
DEPLOYMENT_ACCEPTED=0
DATABASE_TASK_UNCERTAIN=0

usage() {
    cat <<USAGE
Usage: $PROGRAM [--skip-backup]

Safely update momo-backend from the pinned image configured by
MOMO_BACKEND_IMAGE in:
  $NAS_DIR/.env

The default flow is:
  1. Acquire the deployment lock and create/validate a PostgreSQL backup.
  2. Pull the configured, traceable backend image.
  3. Stop every backend instance in this project and verify it is stopped.
  4. Take a final stopped-backend backup, migrate, and check schema identity.
  5. Start momo-backend and wait for its Docker healthcheck to become healthy.

Options:
  --skip-backup  Skip the backup step. Use only when a current, verified backup
                 already exists outside this NAS deployment directory.
  -h, --help     Show this help and exit

If migration or the post-update healthcheck fails after the old backend is
stopped, this script leaves the backend stopped/failed rather than claiming a
successful deployment. The backup path is printed before the update proceeds.
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

momo_context_init
[ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
[ -f "$BACKUP" ] || fail "backup script not found: $BACKUP"
[ -x "$BACKUP" ] || fail "backup script is not executable: $BACKUP"
[ -f "$LOCK_HELPER" ] || fail "deployment lock helper not found: $LOCK_HELPER"
[ -f "$ISOLATION_HELPER" ] || fail "backend isolation helper not found: $ISOLATION_HELPER"
# shellcheck disable=SC1090
. "$LOCK_HELPER"
. "$ISOLATION_HELPER"

momo_deployment_lock_acquire || exit 1
cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    if [ "$MOMO_DATABASE_MODE" != legacy ] && ! momo_client_tasks_quiescent; then
        printf '%s: PostgreSQL client task completion is unknown; deployment lock retained.\n' "$PROGRAM" >&2
        exit 1
    fi
    if [ "$ISOLATION_REQUIRED" -eq 1 ] && [ "$DEPLOYMENT_ACCEPTED" -ne 1 ]; then
        if ! momo_backend_stop_verified || ! momo_deployment_tasks_quiescent; then
            printf '%s: isolation could not be verified; deployment lock retained, inspect active tasks before manual recovery.\n' "$PROGRAM" >&2
            exit 1
        fi
        if [ "$DATABASE_TASK_UNCERTAIN" -eq 1 ]; then
            printf '%s: database task completion is unknown; lock retained for manual inspection.\n' "$PROGRAM" >&2
            exit 1
        fi
        printf '%s: update incomplete; backend remains stopped. Do not restart against an unverified database.\n' "$PROGRAM" >&2
    fi
    momo_deployment_lock_release
    exit "$status"
}
trap cleanup 0
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

wait_for_service_health() {
    service=$1
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        container_ids=$(compose ps --all -q "$service") || return 1
        all_healthy=1
        [ -n "$container_ids" ] || all_healthy=0
        for container_id in $container_ids; do
            health=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
                "$container_id") || return 1
            case "$health" in
                'running healthy')
                    ;;
                'running starting'|'restarting '*|'created '*)
                    all_healthy=0
                    ;;
                *) return 1 ;;
            esac
        done
        [ "$all_healthy" -eq 0 ] || return 0
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

[ ! -e "$NAS_DIR/.momobox-restored" ] || fail "restored database remains quarantined"
if [ "$MOMO_DATABASE_MODE" != legacy ]; then
    [ "$SKIP_BACKUP" -eq 0 ] || fail "new deployments cannot skip backups"
    momo_database_ready
    momo_update_admission
fi

if [ "$SKIP_BACKUP" -eq 0 ]; then
    BACKUP_PATH=$(momo_backup_child) || fail "backup failed; no image was pulled or service was stopped"
    printf '%s\n' "Backup created: $BACKUP_PATH"
else
    printf '%s\n' 'WARNING: skipping backup at caller request.' >&2
fi

# Pull before stopping a healthy service so registry failures do not create
# downtime. The image is pinned by MOMO_BACKEND_IMAGE in the NAS .env file.
compose pull momo-backend || fail "failed to pull momo-backend; current service was left unchanged"

ISOLATION_REQUIRED=1
momo_backend_stop_verified || fail "failed to stop and verify all backend containers before migration"

momo_database_ready
if [ "$MOMO_DATABASE_MODE" != legacy ]; then momo_pg writers || fail "database writers remain"; fi

# The earlier online dump is a preparation point, not the final upgrade point.
# This closes this project's backend writes; other writers must be isolated by
# the operator. A failed final backup must never fall back to the online dump.
if [ "$SKIP_BACKUP" -eq 0 ]; then
    FINAL_BACKUP_PATH=$(momo_backup_child) || fail "final backup failed; backend remains stopped, migration was not started"
    printf '%s\n' "Final stopped-backend backup created: $FINAL_BACKUP_PATH"
fi
momo_backend_verify_stopped || fail "backend restarted during final backup; migration refused"
if [ "$MOMO_DATABASE_MODE" != legacy ]; then
    momo_pg writers || fail "database writers appeared during final backup"
    momo_update_admission
fi

DATABASE_TASK_UNCERTAIN=1
if compose run --rm --no-deps momo-backend migrate; then
    DATABASE_TASK_UNCERTAIN=0
else
    printf '%s: migration failed or its result is unknown; backend remains stopped and the lock requires manual review.\n' "$PROGRAM" >&2
    exit 1
fi

compose run --rm --no-deps momo-backend schema-check || fail "schema identity check failed after migration; backend remains stopped"
momo_backend_verify_stopped || fail "backend became active before validated start"

compose up -d momo-backend >/dev/null
if ! wait_for_service_health momo-backend; then
    printf '%s: momo-backend did not become healthy within 60 seconds; inspect compose logs before retrying.\n' "$PROGRAM" >&2
    exit 1
fi

DEPLOYMENT_ACCEPTED=1
printf '%s\n' 'MomoBox backend update completed successfully and passed its healthcheck.'
