#!/bin/sh
# Shared, dependency-free deployment lock for update/backup/restore.
#
# The lock uses mkdir because it is atomic and is available on minimal NAS
# systems without flock. It deliberately fails closed when a lock already
# exists; stale locks must be inspected and removed by an operator.

momo_deployment_lock_acquire() {
    : "${NAS_DIR:?NAS_DIR must be set before acquiring the deployment lock}"

    if [ "${MOMO_CONTEXT_EXPLICIT:-0}" -eq 1 ] &&
        [ -n "${MOMOBOX_DEPLOYMENT_LOCK_DIR:-}" ] &&
        [ "$MOMOBOX_DEPLOYMENT_LOCK_DIR" != "$NAS_DIR/.momobox-deployment.lock" ]; then
        printf '%s\n' 'explicit deployment lock must belong to its canonical directory' >&2
        return 1
    fi
    MOMOBOX_DEPLOYMENT_LOCK_DIR=${MOMOBOX_DEPLOYMENT_LOCK_DIR:-$NAS_DIR/.momobox-deployment.lock}
    export MOMOBOX_DEPLOYMENT_LOCK_DIR
    MOMOBOX_DEPLOYMENT_LOCK_CREATED=0

    # update.sh calls backup.sh as a child process. Reuse the lock that the
    # parent already owns instead of allowing the nested backup to deadlock.
    if [ "${MOMOBOX_DEPLOYMENT_LOCK_HELD:-0}" = 1 ]; then
        [ -d "$MOMOBOX_DEPLOYMENT_LOCK_DIR" ] || {
            printf '%s: deployment lock environment is set but the lock is missing: %s\n' \
                "${PROGRAM:-momo-box}" "$MOMOBOX_DEPLOYMENT_LOCK_DIR" >&2
            return 1
        }
        [ -n "${MOMOBOX_DEPLOYMENT_LOCK_LEASE:-}" ] && [ -f "$MOMOBOX_DEPLOYMENT_LOCK_DIR/$MOMOBOX_DEPLOYMENT_LOCK_LEASE" ] &&
            [ "$(cat "$MOMOBOX_DEPLOYMENT_LOCK_DIR/context" 2>/dev/null)" = "${MOMO_CONTEXT_KEY:-$NAS_DIR}" ] || {
            printf '%s\n' 'deployment lock lease/context mismatch; refusing inherited lock' >&2
            return 1
        }
        MOMOBOX_DEPLOYMENT_LOCK_CREATED=0
        export MOMOBOX_DEPLOYMENT_LOCK_HELD
        return 0
    fi

    if ! mkdir "$MOMOBOX_DEPLOYMENT_LOCK_DIR" 2>/dev/null; then
        printf '%s: another update, backup, or restore is already running (%s)\n' \
            "${PROGRAM:-momo-box}" "$MOMOBOX_DEPLOYMENT_LOCK_DIR" >&2
        return 1
    fi

    MOMOBOX_DEPLOYMENT_LOCK_CREATED=1
    MOMOBOX_DEPLOYMENT_LOCK_HELD=1
    export MOMOBOX_DEPLOYMENT_LOCK_CREATED MOMOBOX_DEPLOYMENT_LOCK_HELD
    umask 077
    lease_path=$(mktemp "$MOMOBOX_DEPLOYMENT_LOCK_DIR/lease.XXXXXX") || return 1
    MOMOBOX_DEPLOYMENT_LOCK_LEASE=${lease_path##*/}
    printf '%s\n' "${MOMO_CONTEXT_KEY:-$NAS_DIR}" >"$MOMOBOX_DEPLOYMENT_LOCK_DIR/context" || return 1
    export MOMOBOX_DEPLOYMENT_LOCK_LEASE

    # Metadata is informational only; the directory itself is the lock.
    # Keep the file write best-effort so a read-only NAS metadata filesystem
    # cannot leave a lock that the script cannot release.
    {
        printf 'pid=%s\n' "$$"
        printf 'program=%s\n' "${PROGRAM:-unknown}"
        printf 'started_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)"
    } >"$MOMOBOX_DEPLOYMENT_LOCK_DIR/owner" 2>/dev/null || true
}

momo_deployment_lock_release() {
    if [ "${MOMOBOX_DEPLOYMENT_LOCK_CREATED:-0}" = 1 ] &&
        [ -n "${MOMOBOX_DEPLOYMENT_LOCK_DIR:-}" ]; then
        if [ "${MOMO_CONTEXT_EXPLICIT:-0}" -eq 1 ] && ! momo_context_unchanged; then
            printf '%s\n' 'deployment configuration changed; lock retained for manual verification' >&2
            return 1
        fi
        rm -f "$MOMOBOX_DEPLOYMENT_LOCK_DIR/owner" 2>/dev/null || true
        rm -f "$MOMOBOX_DEPLOYMENT_LOCK_DIR/context" "$MOMOBOX_DEPLOYMENT_LOCK_DIR/${MOMOBOX_DEPLOYMENT_LOCK_LEASE:-lease-missing}" 2>/dev/null || true
        rmdir "$MOMOBOX_DEPLOYMENT_LOCK_DIR" 2>/dev/null || true
        MOMOBOX_DEPLOYMENT_LOCK_CREATED=0
        export MOMOBOX_DEPLOYMENT_LOCK_CREATED
    fi
}
