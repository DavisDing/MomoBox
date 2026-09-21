#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
NAS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=$NAS_DIR/compose.yaml
BACKUP=$SCRIPT_DIR/backup.sh
SKIP_BACKUP=0
BACKEND_STOPPED=0

usage() {
    cat <<USAGE
Usage: $PROGRAM [--skip-backup]

Safely update momo-backend from the image configured by MOMO_BACKEND_IMAGE in:
  $NAS_DIR/.env

The default flow is:
  1. Create and validate a PostgreSQL backup.
  2. Pull the configured backend image (normally GHCR :latest).
  3. Stop the currently running backend before schema migration.
  4. Run momo-backend migrate against PostgreSQL.
  5. Start momo-backend with the pulled image.

Options:
  --skip-backup  Skip the backup step. Use only when a current, verified backup
                 already exists outside this NAS deployment directory.
  -h, --help     Show this help and exit

If migration fails after the old backend is stopped, this script leaves the
backend stopped rather than starting an image against an unverified schema.
The backup path is printed before the update proceeds.
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
[ -x "$BACKUP" ] || fail "backup script is not executable: $BACKUP"

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

if [ "$SKIP_BACKUP" -eq 0 ]; then
    BACKUP_PATH=$($BACKUP) || fail "backup failed; no image was pulled or service was stopped"
    printf '%s\n' "Backup created: $BACKUP_PATH"
else
    printf '%s\n' 'WARNING: skipping backup at caller request.' >&2
fi

# Pull before stopping a healthy service so transient registry failures do not
# create downtime. `docker compose pull` re-resolves the mutable :latest tag.
compose pull momo-backend || fail "failed to pull momo-backend; current service was left unchanged"

if compose ps --status running --services 2>/dev/null | grep -Fx 'momo-backend' >/dev/null 2>&1; then
    compose stop momo-backend >/dev/null || fail "failed to stop momo-backend before migration"
    BACKEND_STOPPED=1
fi

compose up -d postgres >/dev/null
wait_for_postgres || fail "postgres did not become ready within 60 seconds"

if ! compose run --rm momo-backend migrate; then
    if [ "$BACKEND_STOPPED" -eq 1 ]; then
        printf '%s\n' "$PROGRAM: migration failed; momo-backend remains stopped to avoid running against an unverified schema." >&2
    fi
    exit 1
fi

compose up -d momo-backend
printf '%s\n' 'MomoBox backend update completed successfully.'
