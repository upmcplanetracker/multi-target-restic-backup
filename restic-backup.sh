#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="${1:-${RESTIC_BACKUP_CONFIG:-/etc/restic-backup.env}}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config file not found: ${CONFIG_FILE}" >&2
    echo "Copy .env.example to ${CONFIG_FILE} (or pass a path as the first argument, or set RESTIC_BACKUP_CONFIG) and edit it." >&2
    exit 1
fi

source "${CONFIG_FILE}"

: "${BACKUP_SOURCE:?BACKUP_SOURCE must be set in ${CONFIG_FILE}}"
: "${LOCAL_REPO:?LOCAL_REPO must be set in ${CONFIG_FILE}}"
: "${LOCAL_PASSWORD_FILE:?LOCAL_PASSWORD_FILE must be set in ${CONFIG_FILE}}"
: "${LOCAL_TMP:?LOCAL_TMP must be set in ${CONFIG_FILE}}"
: "${EXCLUDE_FILE:?EXCLUDE_FILE must be set in ${CONFIG_FILE}}"

readonly BACKUP_SOURCE
readonly LOCAL_REPO
readonly LOCAL_PASSWORD_FILE
readonly LOCAL_TMP
readonly EXCLUDE_FILE
readonly LOCK_FILE="${LOCK_FILE:-/var/run/restic-backup.lock}"
readonly LOG_FILE="${LOG_FILE:-/var/log/restic-backup.log}"
readonly KEEP_DAILY="${KEEP_DAILY:-7}"
readonly RESTIC_TAG="${RESTIC_TAG:-daily}"
readonly RESTIC_HOST="${RESTIC_HOST:-$(hostname)}"
readonly RESTIC_BIN="$(command -v restic || echo /usr/bin/restic)"

readonly ENABLED_TARGETS="${ENABLED_TARGETS:-}"

readonly MAIL_TO="${MAIL_TO:-}"
readonly MAIL_SUBJECT_TAG="${MAIL_SUBJECT_TAG:-[restic-backup]}"
readonly MAIL_BIN="$(command -v mail || echo /usr/bin/mail)"

export RESTIC_REPOSITORY="${LOCAL_REPO}"
export RESTIC_PASSWORD_FILE="${LOCAL_PASSWORD_FILE}"

declare -a FAILURES=()
declare -a MODULE_SUMMARY=()

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}" || true
}

send_email() {
    local subject="$1"
    local body="$2"

    if [[ -z "${MAIL_TO}" ]]; then
        log "WARNING: MAIL_TO not configured -- skipping email notification (subject: ${subject})"
        return 0
    fi

    if [[ ! -x "${MAIL_BIN}" ]]; then
        log "WARNING: 'mail' binary not found -- skipping email notification (subject: ${subject}). See README.md for mail setup."
        return 0
    fi

    if ! printf '%s\n' "${body}" | "${MAIL_BIN}" -s "${MAIL_SUBJECT_TAG} ${subject}" "${MAIL_TO}"; then
        log "WARNING: failed to send notification email (subject: ${subject})"
    fi
}

fail() {
    local msg="$1"
    log "ERROR: ${msg}"
    local body
    body="$(cat <<EOF
restic-backup.sh on $(hostname) could not start.

Reason: ${msg}

Time: $(date '+%Y-%m-%d %H:%M:%S')

--- last 30 log lines ---
$(tail -n 30 "${LOG_FILE}" 2>/dev/null || echo '(no log yet)')
EOF
)"
    send_email "FAILED -- backup did not start" "${body}"
    exit 1
}

on_unexpected_error() {
    local line="$1"
    local cmd="$2"
    log "ERROR: unexpected failure at line ${line}: '${cmd}'"
    local body
    body="$(cat <<EOF
restic-backup.sh on $(hostname) hit an unexpected error outside the normal per-target modules.

Line: ${line}
Command: ${cmd}
Time: $(date '+%Y-%m-%d %H:%M:%S')

--- last 40 log lines ---
$(tail -n 40 "${LOG_FILE}" 2>/dev/null || echo '(no log yet)')
EOF
)"
    send_email "FAILED -- unexpected error" "${body}"
}
trap 'on_unexpected_error "${LINENO}" "${BASH_COMMAND}"' ERR

if [[ "${EUID}" -ne 0 ]]; then
    fail "must run as root (needed to preserve ownership/ACLs on ${BACKUP_SOURCE})"
fi

if [[ ! -x "${RESTIC_BIN}" ]]; then
    fail "restic binary not found. Install it first -- see README.md"
fi

if [[ ! -d "${BACKUP_SOURCE}" ]]; then
    fail "backup source ${BACKUP_SOURCE} does not exist"
fi

if [[ ! -f "${LOCAL_PASSWORD_FILE}" ]]; then
    fail "local repo password file missing: ${LOCAL_PASSWORD_FILE}"
fi

if [[ ! -f "${EXCLUDE_FILE}" ]]; then
    fail "exclude file missing: ${EXCLUDE_FILE}"
fi

mkdir -p "$(dirname "${LOG_FILE}")"
mkdir -p "${LOCAL_REPO}"
mkdir -p "${LOCAL_TMP}"
export TMPDIR="${LOCAL_TMP}"

mkdir -p "$(dirname "${LOCK_FILE}")"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    fail "another backup run is already in progress (lock: ${LOCK_FILE})"
fi

log "===== Starting restic backup ====="

module_local_backup() (
    set +e
    log "--- [local] Backing up ${BACKUP_SOURCE} to ${LOCAL_REPO} ---"

    if ! "${RESTIC_BIN}" snapshots >/dev/null 2>&1; then
        log "[local] Repository not initialized (or unreadable) -- initializing at ${LOCAL_REPO}"
        if ! "${RESTIC_BIN}" init 2>&1 | tee -a "${LOG_FILE}"; then
            log "[local] ERROR: repo init failed"
            return 1
        fi
    fi

    if ! "${RESTIC_BIN}" backup "${BACKUP_SOURCE}" \
        --one-file-system \
        --exclude-file="${EXCLUDE_FILE}" \
        --tag "${RESTIC_TAG}" \
        --host "${RESTIC_HOST}" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log "[local] ERROR: restic backup failed"
        return 1
    fi
    log "[local] Backup complete."

    log "[local] Applying retention policy (keep last ${KEEP_DAILY} daily snapshots) ..."
    if ! "${RESTIC_BIN}" forget \
        --tag "${RESTIC_TAG}" \
        --host "${RESTIC_HOST}" \
        --keep-daily "${KEEP_DAILY}" \
        --prune \
        2>&1 | tee -a "${LOG_FILE}"; then
        log "[local] ERROR: retention/prune failed"
        return 1
    fi
    log "[local] Retention/prune complete."
    return 0
)

module_copy_target() (
    set +e
    local name="$1"

    if [[ ! "${name}" =~ ^[A-Za-z0-9_]+$ ]]; then
        log "[${name}] ERROR: invalid target name -- only letters, digits, and underscores are allowed (used to build TARGET_${name^^}_* variable names)"
        return 1
    fi

    local upper="${name^^}"
    local type_var="TARGET_${upper}_TYPE"
    local repo_var="TARGET_${upper}_REPO"
    local pass_var="TARGET_${upper}_PASSWORD_FILE"
    local mount_var="TARGET_${upper}_MOUNTPOINT"
    local env_var="TARGET_${upper}_ENV_FILE"

    local type="${!type_var:-}"
    local repo="${!repo_var:-}"
    local password_file="${!pass_var:-}"
    local mountpoint="${!mount_var:-}"
    local env_file="${!env_var:-}"

    log "--- [${name}] Copying snapshots to '${name}' repository (type: ${type:-unset}) ---"

    if [[ -z "${type}" || -z "${repo}" || -z "${password_file}" ]]; then
        log "[${name}] ERROR: incomplete config -- ${type_var}, ${repo_var}, and ${pass_var} must all be set"
        return 1
    fi

    if [[ ! -f "${password_file}" ]]; then
        log "[${name}] ERROR: password file missing: ${password_file}"
        return 1
    fi

    case "${type}" in
        path)
            if [[ -n "${mountpoint}" ]] && ! mountpoint -q "${mountpoint}"; then
                log "[${name}] ERROR: ${mountpoint} is not mounted"
                return 1
            fi
            ;;
        s3)
            if [[ -z "${env_file}" ]]; then
                log "[${name}] ERROR: ${env_var} must be set for an s3-type target"
                return 1
            fi
            if [[ ! -f "${env_file}" ]]; then
                log "[${name}] ERROR: credentials file missing: ${env_file}"
                return 1
            fi
            # shellcheck disable=SC1090
            if ! source "${env_file}"; then
                log "[${name}] ERROR: failed to source credentials file ${env_file}"
                return 1
            fi
            if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
                log "[${name}] ERROR: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not set after sourcing ${env_file} -- file present but empty or malformed"
                return 1
            fi
            ;;
        *)
            log "[${name}] ERROR: unknown ${type_var}='${type}' (expected 'path' or 's3')"
            return 1
            ;;
    esac

    if ! "${RESTIC_BIN}" -r "${repo}" --password-file "${password_file}" snapshots >/dev/null 2>&1; then
        log "[${name}] Repository not initialized -- initializing at ${repo}"
        if ! "${RESTIC_BIN}" -r "${repo}" --password-file "${password_file}" init 2>&1 | tee -a "${LOG_FILE}"; then
            log "[${name}] ERROR: repo init failed"
            return 1
        fi
    fi

    if ! "${RESTIC_BIN}" copy \
        --from-repo "${LOCAL_REPO}" \
        --from-password-file "${LOCAL_PASSWORD_FILE}" \
        -r "${repo}" \
        --password-file "${password_file}" \
        --tag "${RESTIC_TAG}" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log "[${name}] ERROR: copy failed"
        return 1
    fi
    log "[${name}] Copy complete."

    log "[${name}] Applying retention policy (keep last ${KEEP_DAILY} daily snapshots) ..."
    if ! "${RESTIC_BIN}" -r "${repo}" --password-file "${password_file}" forget \
        --tag "${RESTIC_TAG}" \
        --host "${RESTIC_HOST}" \
        --keep-daily "${KEEP_DAILY}" \
        --prune \
        2>&1 | tee -a "${LOG_FILE}"; then
        log "[${name}] ERROR: retention/prune failed"
        return 1
    fi
    log "[${name}] Retention/prune complete."
    return 0
)

module_integrity_check() (
    set +e
    log "--- [check] Running local repository structure check ---"
    if ! "${RESTIC_BIN}" check 2>&1 | tee -a "${LOG_FILE}"; then
        log "[check] ERROR: repository check failed"
        return 1
    fi
    return 0
)


if module_local_backup; then
    MODULE_SUMMARY+=("local: OK")
else
    MODULE_SUMMARY+=("local: FAILED")
    FAILURES+=("local backup")
fi

for target in ${ENABLED_TARGETS}; do
    if module_copy_target "${target}"; then
        MODULE_SUMMARY+=("${target}: OK")
    else
        MODULE_SUMMARY+=("${target}: FAILED")
        FAILURES+=("${target} copy")
    fi
done

if module_integrity_check; then
    MODULE_SUMMARY+=("local repo integrity check: OK")
else
    MODULE_SUMMARY+=("local repo integrity check: FAILED")
    FAILURES+=("local repository integrity check")
fi

# ---- Wrap-up ----------------------------------------------------------------------
log "===== Module summary ====="
for line in "${MODULE_SUMMARY[@]}"; do
    log "  ${line}"
done

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    log "===== restic backup finished WITH FAILURES ====="
    summary_text="$(printf '%s\n' "${MODULE_SUMMARY[@]}")"
    failed_text="$(printf '  - %s\n' "${FAILURES[@]}")"
    failure_body="$(cat <<EOF
restic-backup.sh on $(hostname) completed with ${#FAILURES[@]} failed step(s).

Failed steps:
${failed_text}

Full module summary:
${summary_text}

Time: $(date '+%Y-%m-%d %H:%M:%S')

--- last 60 log lines ---
$(tail -n 60 "${LOG_FILE}")
EOF
)"
    send_email "FAILED (${#FAILURES[@]} of ${#MODULE_SUMMARY[@]} steps)" "${failure_body}"
    exit 1
fi

log "===== restic backup finished successfully ====="
exit 0
