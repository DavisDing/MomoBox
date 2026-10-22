#!/bin/sh
# Runs ONLY inside an approved postgres client image. No credentials in argv.
set -eu
umask 077
fail() { printf '%s\n' "PostgreSQL operation refused: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail "one operation is required"
operation=$1
case "$operation" in probe|dump|dump-list|writers|empty|restore-candidate|schema-signature) ;; *) fail "unknown operation" ;; esac
unset PGHOST PGPORT PGUSER PGPASSWORD PGSERVICE PGSERVICEFILE PGPASSFILE PGOPTIONS PGDATABASE
awk -f /momo/pg-connection.awk </dev/null || fail "unsupported or mismatched database URI"
chmod 600 /tmp/momo-service.conf /tmp/momo.pgpass
export PGSERVICE=momobox PGSERVICEFILE=/tmp/momo-service.conf PGPASSFILE=/tmp/momo.pgpass
unset DATABASE_URL
query() {
    # libpq can report connection detail; keep raw diagnostics private in tmpfs.
    psql -X --no-password -A -t -v ON_ERROR_STOP=1 -c "$1" 2>/tmp/momo-pg-error || fail "database query failed (check identity, connectivity and permissions privately)"
}
client_major=$(pg_dump --version | sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p')
identity=$(query "SELECT current_database() || '|' || current_user || '|' || (current_setting('server_version_num')::int / 10000)::text")
expected="${MOMO_EXPECTED_DATABASE:?}|${MOMO_EXPECTED_ROLE:?}|$client_major"
[ "$identity" = "$expected" ] || fail "database, role or client/server major mismatch"
case "$client_major" in 16|18) ;; *) fail "only PostgreSQL 16 and 18 are supported by these operations" ;; esac
if [ "${MOMO_DATABASE_MODE:?}" = external ]; then
    flags=$(query "SELECT (NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls AND NOT EXISTS (SELECT 1 FROM pg_auth_members WHERE member = pg_roles.oid))::text FROM pg_roles WHERE rolname=current_user")
    [ "$flags" = true ] || fail "external role must be dedicated, nonprivileged, and have no inherited role memberships"
fi
case "$operation" in
    probe)
        server_address=$(query "SELECT inet_server_addr()::text || ':' || inet_server_port()::text") || exit 1
        database_oid=$(query "SELECT oid FROM pg_database WHERE datname=current_database()") || exit 1
        printf 'database=%s\nrole=%s\npg_major=%s\n' "$MOMO_EXPECTED_DATABASE" "$MOMO_EXPECTED_ROLE" "$client_major"
        printf 'server_address=%s\ndatabase_oid=%s\n' "$server_address" "$database_oid"
        if [ "$MOMO_DATABASE_MODE" = managed ]; then
            cluster=$(query 'SELECT system_identifier FROM pg_control_system()') || exit 1
            printf 'cluster=%s\n' "$cluster"
        fi
        ;;
    dump) pg_dump --no-password --format=custom --no-owner --no-privileges 2>/tmp/momo-pg-error || fail "pg_dump failed" ;;
    dump-list) pg_restore --list 2>/tmp/momo-pg-error >/dev/null || fail "archive is unreadable" ;;
    schema-signature) query "SELECT md5(COALESCE(string_agg(version::text || ':' || name || ':' || checksum, '|' ORDER BY version), '')) FROM schema_migrations" ;;
    writers)
        count=$(query "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()")
        [ "$count" = 0 ] || fail "other database clients are present; isolate all MomoBox writers" ;;
    empty|restore-candidate)
        count=$(query "SELECT
          (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp_%') +
          (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e')) +
          (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_type'::regclass AND d.objid=t.oid AND d.deptype='e')) +
          (SELECT count(*) FROM pg_namespace WHERE nspname NOT IN ('public','pg_catalog','information_schema') AND nspname NOT LIKE 'pg_toast%' AND nspname NOT LIKE 'pg_temp_%')")
        [ "$count" = 0 ] || fail "candidate database is not empty"
        sessions=$(query "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()")
        [ "$sessions" = 0 ] || fail "candidate database has other clients"
        if [ "$operation" = restore-candidate ]; then
            pg_restore --dbname=service=momobox --no-password --exit-on-error --single-transaction --no-owner --no-privileges 2>/tmp/momo-pg-error || fail "candidate restore failed"
        fi ;;
esac
