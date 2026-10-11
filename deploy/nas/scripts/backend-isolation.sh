#!/bin/sh
# Loaded by update/restore after compose() is defined. Scope: this project only.
# A stop must cover restarting containers too, not just a running ps snapshot.
momo_backend_stop_verified() {
    compose stop momo-backend >/dev/null || return 1
    momo_backend_verify_stopped
}

momo_backend_verify_stopped() {
    backend_ids=$(compose ps --all -q momo-backend) || return 1
    for backend_id in $backend_ids; do
        backend_state=$(docker inspect --format '{{.State.Status}}' "$backend_id") || return 1
        case "$backend_state" in
            exited|created) ;;
            *) printf '%s: backend is not safely stopped (%s)\n' "${PROGRAM:-momo-box}" "$backend_state" >&2; return 1 ;;
        esac
    done
}

# An interruption may leave a daemon-managed one-off task running. Never free
# the deployment lock in that case (or if enumeration fails): manual review is
# required before another script can operate on the database.
momo_deployment_tasks_quiescent() {
    deployment_ids=$(compose ps --all -q momo-backend) || return 1
    for deployment_id in $deployment_ids; do
        deployment_state=$(docker inspect --format '{{.State.Status}}' "$deployment_id") || return 1
        case "$deployment_state" in
            exited|created) ;;
            *) return 1 ;;
        esac
    done
}
