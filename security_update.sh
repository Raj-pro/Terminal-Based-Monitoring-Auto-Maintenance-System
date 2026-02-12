#!/usr/bin/env bash
# security_update.sh — Install security-only patches, log results, alert on failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.conf"

mkdir -p "${SCRIPT_DIR}/${LOG_DIR}"

LOG_FILE="${SCRIPT_DIR}/${SECURITY_LOG}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_msg() {
    local msg="[${TIMESTAMP}] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_msg "==============================================================================="
log_msg " SECURITY-ONLY PATCH UPDATE — $(hostname)"
log_msg " Started: ${TIMESTAMP}"
log_msg "==============================================================================="
log_msg ""

UPDATE_SUCCESS=true
UPDATE_OUTPUT=""

# Detect distro and run security updates
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO="${ID:-unknown}"
    log_msg "Detected distribution: ${PRETTY_NAME:-${DISTRO}}"
else
    DISTRO="unknown"
    log_msg "WARNING: Could not detect distribution from /etc/os-release"
fi

case "$DISTRO" in
    ubuntu|debian)
        log_msg ""
        log_msg "Running Debian/Ubuntu security-only updates..."
        log_msg ""

        if command -v unattended-upgrade &>/dev/null; then
            log_msg "Using: unattended-upgrade -d"
            UPDATE_OUTPUT=$(sudo unattended-upgrade -d 2>&1) || UPDATE_SUCCESS=false
            echo "$UPDATE_OUTPUT" | tail -20 >> "$LOG_FILE"
        else
            log_msg "Using apt-get with security sources..."
            sudo apt-get update -y 2>&1 | tail -3 >> "$LOG_FILE"

            if [[ -f /etc/apt/sources.list ]]; then
                UPDATE_OUTPUT=$(sudo apt-get upgrade -y \
                    -o Dir::Etc::sourcelist="/etc/apt/sources.list" \
                    -o Dir::Etc::sourceparts="-" \
                    --with-new-pkgs 2>&1) || UPDATE_SUCCESS=false
                echo "$UPDATE_OUTPUT" | tail -20 >> "$LOG_FILE"
            else
                log_msg "WARNING: /etc/apt/sources.list not found."
                UPDATE_SUCCESS=false
            fi
        fi
        ;;

    rhel|centos|rocky|alma)
        log_msg ""
        log_msg "Running RHEL/CentOS security-only updates..."
        log_msg ""

        if command -v yum &>/dev/null; then
            log_msg "Using: yum update --security"
            UPDATE_OUTPUT=$(sudo yum update --security -y 2>&1) || UPDATE_SUCCESS=false
            echo "$UPDATE_OUTPUT" | tail -20 >> "$LOG_FILE"
        elif command -v dnf &>/dev/null; then
            log_msg "Using: dnf update --security"
            UPDATE_OUTPUT=$(sudo dnf update --security -y 2>&1) || UPDATE_SUCCESS=false
            echo "$UPDATE_OUTPUT" | tail -20 >> "$LOG_FILE"
        else
            log_msg "ERROR: Neither yum nor dnf found."
            UPDATE_SUCCESS=false
        fi
        ;;

    fedora)
        log_msg ""
        log_msg "Running Fedora security-only updates..."
        log_msg ""
        if command -v dnf &>/dev/null; then
            log_msg "Using: dnf update --security"
            UPDATE_OUTPUT=$(sudo dnf update --security -y 2>&1) || UPDATE_SUCCESS=false
            echo "$UPDATE_OUTPUT" | tail -20 >> "$LOG_FILE"
        else
            log_msg "ERROR: dnf not found."
            UPDATE_SUCCESS=false
        fi
        ;;

    *)
        log_msg "ERROR: Unsupported distribution '${DISTRO}'."
        log_msg "Supported: ubuntu, debian, rhel, centos, rocky, alma, fedora"
        UPDATE_SUCCESS=false
        ;;
esac

log_msg ""

# Result and alerting
if [[ "$UPDATE_SUCCESS" == "true" ]]; then
    log_msg "RESULT: ✓ Security patches applied successfully."
else
    log_msg "RESULT: ✗ Security patch update FAILED or partially failed."

    if [[ "${EMAIL_ENABLED}" == "true" ]] && command -v mail &>/dev/null; then
        SUBJECT="${EMAIL_SUBJECT_PREFIX} Security Update FAILED on $(hostname)"
        echo "Security-only update on $(hostname) failed at ${TIMESTAMP}. Check ${LOG_FILE} for details." | \
            mail -s "$SUBJECT" "$EMAIL_RECIPIENT" 2>/dev/null && \
            log_msg "EMAIL: Failure alert sent to ${EMAIL_RECIPIENT}" || \
            log_msg "EMAIL: Failed to send alert email."
    fi
fi

log_msg ""
log_msg "Current kernel: $(uname -r)"
log_msg ""

log_msg "==============================================================================="
log_msg " SECURITY UPDATE COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
log_msg "==============================================================================="
