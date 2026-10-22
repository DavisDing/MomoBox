#!/bin/sh
# Shared managed/external DB adapter. Legacy default retains its original path.
momo_pg() { compose run --rm --no-deps -T momo-pg-client "$1"; }

momo_database_ready() {
    if [ "$MOMO_DATABASE_MODE" = legacy ]; then
        compose up -d postgres >/dev/null
        wait_for_postgres || fail "postgres did not become ready within 60 seconds"
        return
    fi
    if [ "$MOMO_DATABASE_MODE" = managed ]; then
        compose up -d postgres >/dev/null
        wait_for_postgres || fail "postgres did not become ready within 60 seconds"
    fi
    momo_identity=$(momo_pg probe) || fail "database identity or PG client validation failed"
    if [ "$MOMO_DATABASE_MODE" = managed ]; then
        momo_cluster=$(compose exec -T postgres sh -eu -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -XAt --no-password --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "SELECT system_identifier FROM pg_control_system()"') || fail "cannot inspect managed database identity"
        [ "$(printf '%s\n' "$momo_identity" | sed -n 's/^cluster=//p')" = "$momo_cluster" ] || fail "backend DSN does not point to this managed PostgreSQL cluster"
    fi
}

momo_dump() {
    if [ "$MOMO_DATABASE_MODE" = legacy ]; then
        compose exec -T postgres sh -eu -c 'exec pg_dump --format=custom --no-owner --no-privileges --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'
    else momo_pg dump; fi
}

momo_dump_list() {
    if [ "$MOMO_DATABASE_MODE" = legacy ]; then compose exec -T postgres pg_restore --list >/dev/null
    else momo_pg dump-list; fi
}

momo_backup_metadata() {
    [ "$MOMO_DATABASE_MODE" != legacy ] || return 0
    momo_signature=$(momo_pg schema-signature) || return 1
    [ -n "$momo_signature" ] || return 1
    momo_checksum=$(momo_sha256 "$1") || return 1
    printf 'format=1\n'
    printf '%s\n' "$momo_identity"
    printf 'client_image=%s\n' "$MOMO_PG_CLIENT_IMAGE"
    printf 'schema_signature=%s\n' "$momo_signature"
    printf 'sha256=%s\n' "$momo_checksum"
}

momo_update_admission() {
    [ ! -e "$NAS_DIR/.momobox-restored" ] || fail "restored database remains quarantined; update cannot authorize reopening"
    [ "$MOMO_DATABASE_MODE" != legacy ] || return 0
    [ "$MOMO_EXCLUSIVE_WRITER" -eq 1 ] || fail "new-mode update requires explicit --exclusive-writer attestation"
    [ -n "$MOMO_RESTORE_PROOF" ] && [ -n "$MOMO_PROOF_MAX_AGE" ] || fail "new-mode update requires restore proof and explicit maximum age"
    case "$MOMO_PROOF_MAX_AGE" in ''|*[!0-9]*|0|0*) fail "invalid proof maximum age" ;; esac
    [ "${#MOMO_PROOF_MAX_AGE}" -le 8 ] || fail "proof maximum age exceeds supported bound"
    [ "$(momo_meta_get "$MOMO_RESTORE_PROOF" format)" = 1 ] || fail "unsupported proof format"
    [ "$(momo_meta_get "$MOMO_RESTORE_PROOF" verified)" = candidate-schema-check ] || fail "restore proof is missing or invalid"
    momo_candidate=$(momo_meta_get "$MOMO_RESTORE_PROOF" candidate_database) || fail "proof candidate is missing"
    [ "$momo_candidate" != "$MOMO_EXPECTED_DATABASE" ] || fail "proof candidate must differ from source"
    momo_proof_sum=$(momo_meta_get "$MOMO_RESTORE_PROOF" sha256) || fail "proof checksum is missing"
    [ "${#momo_proof_sum}" -eq 64 ] || fail "invalid proof checksum"
    case "$momo_proof_sum" in *[!a-f0-9]*) fail "invalid proof checksum" ;; esac
    momo_verified=$(momo_meta_get "$MOMO_RESTORE_PROOF" verified_at) || fail "proof timestamp is missing"
    case "$momo_verified" in ''|*[!0-9]*|0*) fail "invalid proof timestamp" ;; esac
    [ "${#momo_verified}" -le 10 ] || fail "proof timestamp exceeds supported bound"
    momo_now=$(date -u +%s)
    [ "$momo_verified" -le "$momo_now" ] && [ "$((momo_now - momo_verified))" -le "$MOMO_PROOF_MAX_AGE" ] || fail "restore proof expired or is in the future"
    for momo_key in database role pg_major server_address database_oid; do
        momo_actual=$(printf '%s\n' "$momo_identity" | sed -n "s/^$momo_key=//p")
        [ "$(momo_meta_get "$MOMO_RESTORE_PROOF" "$momo_key")" = "$momo_actual" ] || fail "restore proof belongs to another database identity"
    done
    if [ "$MOMO_DATABASE_MODE" = managed ]; then
        [ "$(momo_meta_get "$MOMO_RESTORE_PROOF" cluster)" = "$(printf '%s\n' "$momo_identity" | sed -n 's/^cluster=//p')" ] || fail "restore proof cluster differs"
    fi
    [ "$(momo_meta_get "$MOMO_RESTORE_PROOF" client_image)" = "$MOMO_PG_CLIENT_IMAGE" ] || fail "restore proof client image differs"
    momo_signature=$(momo_pg schema-signature) || fail "cannot inspect current migration ledger"
    [ -n "$momo_signature" ] && [ "$(momo_meta_get "$MOMO_RESTORE_PROOF" schema_signature)" = "$momo_signature" ] || fail "restore proof does not match the current migration ledger"
}
