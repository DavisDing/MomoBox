#!/bin/sh

set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
NAS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=$NAS_DIR/compose.yaml
DEFAULT_OUTPUT_DIR=$NAS_DIR/backups
OUTPUT_DIR=$DEFAULT_OUTPUT_DIR

usage() {
    cat <<USAGE
Usage: $PROGRAM [--output-dir DIR]

Create a PostgreSQL custom-format backup using the postgres service in:
  $COMPOSE_FILE

Options:
  -o, --output-dir DIR  Destination directory (default: $DEFAULT_OUTPUT_DIR)
  -h, --help            Show this help and exit

The completed dump path is printed to standard output. The dump is written to a
private temporary file, validated with pg_restore --list, and atomically renamed.
USAGE
}

fail() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case $1 in
        -o|--output-dir)
            [ "$#" -ge 2 ] || fail "$1 requires a directory argument"
            [ -n "$2" ] || fail "$1 requires a non-empty directory argument"
            OUTPUT_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
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

[ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"
command -v date >/dev/null 2>&1 || fail "date is required"

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

cleanup() {
    rm -f "$TEMP_PATH"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Start only PostgreSQL if needed. Compose reads deploy/nas/.env via
# --project-directory; credentials remain inside the container environment.
compose up -d postgres >/dev/null
wait_for_postgres || fail "postgres did not become ready within 60 seconds"

if ! compose exec -T postgres sh -eu -c \
    'exec pg_dump --format=custom --no-owner --no-privileges --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' \
    >"$TEMP_PATH"; then
    fail "pg_dump failed; no completed backup was created"
fi

[ -s "$TEMP_PATH" ] || fail "pg_dump produced an empty file"

if ! compose exec -T postgres pg_restore --list <"$TEMP_PATH" >/dev/null; then
    fail "backup validation failed; no completed backup was created"
fi

# mv is atomic because the temporary and final files are in the same directory.
[ ! -e "$FINAL_PATH" ] || fail "refusing to overwrite existing file: $FINAL_PATH"
mv "$TEMP_PATH" "$FINAL_PATH" || fail "cannot finalize backup"
trap - 0 HUP INT TERM

printf '%s\n' "$FINAL_PATH"
