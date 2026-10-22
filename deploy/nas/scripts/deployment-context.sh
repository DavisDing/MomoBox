#!/bin/sh
# Shared deployment selection. Sourced after SCRIPT_DIR and PROGRAM are set.
MOMO_DEPLOYMENT_DIR=
MOMO_PROJECT_NAME=
MOMO_DATABASE_MODE=legacy
MOMO_DATABASE_MODE_SET=0
MOMO_EXPECTED_DATABASE=
MOMO_EXPECTED_ROLE=
MOMO_PG_CLIENT_IMAGE=
MOMO_RESTORE_PROOF=
MOMO_PROOF_MAX_AGE=
MOMO_EXCLUSIVE_WRITER=0
MOMO_CONTEXT_EXPLICIT=0

momo_context_option() {
    MOMO_OPTION_CONSUMED=0
    case "$1" in
        --deployment-dir|--project-name|--database-mode|--expected-database|--expected-role|--pg-client-image|--restore-proof|--proof-max-age)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a non-empty argument"
            case "$2" in *'
'*) fail "newlines are not allowed in deployment options" ;; esac
            case "$1" in
                --deployment-dir) [ -z "$MOMO_DEPLOYMENT_DIR" ] || fail "duplicate --deployment-dir"; MOMO_DEPLOYMENT_DIR=$2 ;;
                --project-name) [ -z "$MOMO_PROJECT_NAME" ] || fail "duplicate --project-name"; MOMO_PROJECT_NAME=$2 ;;
                --database-mode) [ "$MOMO_DATABASE_MODE_SET" -eq 0 ] || fail "duplicate --database-mode"; MOMO_DATABASE_MODE=$2; MOMO_DATABASE_MODE_SET=1 ;;
                --expected-database) [ -z "$MOMO_EXPECTED_DATABASE" ] || fail "duplicate --expected-database"; MOMO_EXPECTED_DATABASE=$2 ;;
                --expected-role) [ -z "$MOMO_EXPECTED_ROLE" ] || fail "duplicate --expected-role"; MOMO_EXPECTED_ROLE=$2 ;;
                --pg-client-image) [ -z "$MOMO_PG_CLIENT_IMAGE" ] || fail "duplicate --pg-client-image"; MOMO_PG_CLIENT_IMAGE=$2 ;;
                --restore-proof) [ -z "$MOMO_RESTORE_PROOF" ] || fail "duplicate --restore-proof"; MOMO_RESTORE_PROOF=$2 ;;
                --proof-max-age) [ -z "$MOMO_PROOF_MAX_AGE" ] || fail "duplicate --proof-max-age"; MOMO_PROOF_MAX_AGE=$2 ;;
            esac
            MOMO_CONTEXT_EXPLICIT=1
            MOMO_OPTION_CONSUMED=2 ;;
        --exclusive-writer) [ "$MOMO_EXCLUSIVE_WRITER" -eq 0 ] || fail "duplicate --exclusive-writer"; MOMO_EXCLUSIVE_WRITER=1; MOMO_CONTEXT_EXPLICIT=1; MOMO_OPTION_CONSUMED=1 ;;
    esac
}

momo_context_help() {
    cat <<'USAGE'
Shared options for new deployments (all identity options are required):
  --deployment-dir DIR       Canonical deployment directory, containing .env
  --project-name NAME        Existing Compose project identity (not inferred)
  --database-mode MODE       managed or external; no automatic DB discovery
  --expected-database NAME   Assert the actual database, never select a fallback
  --expected-role NAME       Assert the actual connecting role
  --pg-client-image IMAGE    docker.io/library/postgres@sha256:<64 hex digits>
Update also requires --exclusive-writer, --restore-proof FILE and
--proof-max-age SECONDS. They do not authorize a restored database to reopen.
USAGE
}

momo_context_init() {
    NAS_DIR=$(CDPATH= cd -P "${MOMO_DEPLOYMENT_DIR:-$SCRIPT_DIR/..}" && pwd) || fail "deployment directory not found"
    COMPOSE_FILE=$NAS_DIR/docker-compose.yaml
    [ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
    if [ "$MOMO_CONTEXT_EXPLICIT" -eq 1 ]; then
        MOMO_OPS_DIR=$(CDPATH= cd -P "$SCRIPT_DIR/../operations" && pwd) || fail "operations helpers not found"
        [ -n "$MOMO_DEPLOYMENT_DIR" ] && [ -n "$MOMO_PROJECT_NAME" ] || fail "explicit deployments require directory and project name"
        case "$MOMO_PROJECT_NAME" in ''|*[!a-z0-9_-]*|[-_]*) fail "invalid project name" ;; esac
        case "$MOMO_DATABASE_MODE" in managed|external) ;; *) fail "explicit deployments require managed or external mode" ;; esac
        case "$MOMO_EXPECTED_DATABASE" in ''|*[!A-Za-z0-9_]* ) fail "expected database must use letters, digits or underscore" ;; esac
        case "$MOMO_EXPECTED_ROLE" in ''|*[!A-Za-z0-9_]* ) fail "expected role must use letters, digits or underscore" ;; esac
        case "$MOMO_PG_CLIENT_IMAGE" in docker.io/library/postgres@sha256:*) ;; *) fail "PG client must be an explicit official postgres digest" ;; esac
        momo_digest=${MOMO_PG_CLIENT_IMAGE#*@sha256:}
        [ "${#momo_digest}" -eq 64 ] || fail "invalid PG client digest"
        case "$momo_digest" in *[!a-f0-9]*) fail "invalid PG client digest" ;; esac
        [ -f "$NAS_DIR/.env" ] || fail "deployment .env not found"
        MOMO_CLIENT_COMPOSE=$MOMO_OPS_DIR/$MOMO_DATABASE_MODE-client.yaml
        export MOMO_PG_CLIENT_IMAGE MOMO_EXPECTED_DATABASE MOMO_EXPECTED_ROLE MOMO_DATABASE_MODE MOMO_OPS_DIR
        MOMO_COMPOSE_SHA=$(momo_sha256 "$COMPOSE_FILE") || fail "cannot fingerprint Compose"
        MOMO_ENV_SHA=$(momo_sha256 "$NAS_DIR/.env") || fail "cannot fingerprint deployment environment"
    else
        MOMO_CLIENT_COMPOSE=
    fi
    MOMO_CONTEXT_KEY="$NAS_DIR|$MOMO_PROJECT_NAME|$MOMO_DATABASE_MODE|$MOMO_EXPECTED_DATABASE|$MOMO_EXPECTED_ROLE|$MOMO_PG_CLIENT_IMAGE|${MOMO_COMPOSE_SHA:-}|${MOMO_ENV_SHA:-}"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        COMPOSE_KIND=docker
    elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_KIND=docker-compose
    else fail "Docker Compose is required (docker compose or docker-compose)"; fi
}

compose() (
    # Prepend fixed context without eval, word splitting, or sourcing .env.
    if [ "$MOMO_CONTEXT_EXPLICIT" -eq 1 ]; then
        momo_context_unchanged || fail "deployment configuration changed during operation"
        # The selected .env, not the invoking shell, owns the deployed endpoint.
        unset DATABASE_URL DATABASE_NETWORK POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD MOMO_BACKEND_IMAGE APP_VERSION APP_ENV MOMO_BACKEND_PORT JWT_SECRET REFRESH_TOKEN_PEPPER HA_TOKEN_ENCRYPTION_KEY REGISTRATION_MODE ACCESS_TOKEN_TTL REFRESH_TOKEN_TTL MAX_REQUEST_BODY_BYTES LOG_LEVEL COMPOSE_PROFILES
        set -- --project-directory "$NAS_DIR" --project-name "$MOMO_PROJECT_NAME" --env-file "$NAS_DIR/.env" -f "$COMPOSE_FILE" -f "$MOMO_CLIENT_COMPOSE" "$@"
    else set -- --project-directory "$NAS_DIR" -f "$COMPOSE_FILE" "$@"; fi
    if [ "$COMPOSE_KIND" = docker ]; then docker compose "$@"; else docker-compose "$@"; fi
)

momo_context_unchanged() {
    [ "$MOMO_CONTEXT_EXPLICIT" -eq 1 ] || return 0
    [ "$(momo_sha256 "$COMPOSE_FILE")" = "$MOMO_COMPOSE_SHA" ] &&
        [ "$(momo_sha256 "$NAS_DIR/.env")" = "$MOMO_ENV_SHA" ]
}

momo_backup_child() {
    if [ "$MOMO_CONTEXT_EXPLICIT" -eq 0 ]; then "$BACKUP"; return; fi
    "$BACKUP" --deployment-dir "$NAS_DIR" --project-name "$MOMO_PROJECT_NAME" \
        --database-mode "$MOMO_DATABASE_MODE" --expected-database "$MOMO_EXPECTED_DATABASE" \
        --expected-role "$MOMO_EXPECTED_ROLE" --pg-client-image "$MOMO_PG_CLIENT_IMAGE"
}

momo_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then momo_sum=$(sha256sum "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then momo_sum=$(shasum -a 256 "$1") || return 1
    else fail "sha256sum or shasum is required"; fi
    printf '%s\n' "${momo_sum%% *}"
}

momo_meta_get() {
    [ -f "$1" ] || return 1
    momo_value=$(sed -n "s/^$2=//p" "$1") || return 1
    [ "$(printf '%s\n' "$momo_value" | wc -l | tr -d ' ')" -eq 1 ] && [ -n "$momo_value" ] || return 1
    printf '%s\n' "$momo_value"
}
