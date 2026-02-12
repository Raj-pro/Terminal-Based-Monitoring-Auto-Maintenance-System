#!/usr/bin/env bash
###############################################################################
#  self_heal.sh — Self-Healing Service Monitor
#
#  Checks critical services defined in config.conf. If a service is down,
#  attempts to restart it (up to MAX_RESTART_RETRIES times).
#  Logs all actions to self_heal.log and sends alerts on failure.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.conf"

mkdir -p "${SCRIPT_DIR}/${LOG_DIR}"

LOG_FILE="${SCRIPT_DIR}/${SELF_HEAL_LOG}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_msg() {
    echo "[${TIMESTAMP}] $1" | tee -a "$LOG_FILE"
}

# ── Check if systemctl is available ───────────────────────────────────────────
if ! command -v systemctl &>/dev/null; then
    log_msg "ERROR: systemctl not available. Self-healing requires systemd."
    exit 1
fi

log_msg "═══════════════════════════════════════════════════════════════"
log_msg " SELF-HEALING SERVICE CHECK — $(hostname)"
log_msg "═══════════════════════════════════════════════════════════════"
log_msg "Checking services: ${CRITICAL_SERVICES}"
log_msg ""

# ── Iterate over critical services ────────────────────────────────────────────
overall_failures=0

for service in $CRITICAL_SERVICES; do
    log_msg "──────────────────────────────────────────────────────────────"
    log_msg "Checking service: ${service}"

    # Check if the service unit exists
    if ! systemctl list-unit-files "${service}.service" &>/dev/null; then
        log_msg "  SKIP: Service '${service}' not found on this system."
        continue
    fi

    # Check if active
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        log_msg "  STATUS: ✓ ${service} is running."
        continue
    fi

    # Service is down — attempt restart
    log_msg "  STATUS: ✗ ${service} is NOT running!"
    restart_success=false

    for attempt in $(seq 1 "$MAX_RESTART_RETRIES"); do
        log_msg "  RESTART ATTEMPT: ${attempt}/${MAX_RESTART_RETRIES}"

        if sudo systemctl restart "${service}" 2>/dev/null; then
            sleep 2  # Give service time to start

            if systemctl is-active --quiet "${service}" 2>/dev/null; then
                log_msg "  RESULT: ✓ ${service} restarted successfully on attempt ${attempt}."
                restart_success=true
                break
            else
                log_msg "  RESULT: ✗ ${service} did not come up after restart attempt ${attempt}."
            fi
        else
            log_msg "  RESULT: ✗ Failed to execute restart for ${service} (attempt ${attempt})."
        fi
    done

    if [[ "$restart_success" != "true" ]]; then
        log_msg "  ESCALATION: ✗✗ ${service} FAILED after ${MAX_RESTART_RETRIES} attempts!"
        ((overall_failures++))

        # Send alert
        if [[ "${EMAIL_ENABLED}" == "true" ]] && command -v mail &>/dev/null; then
            SUBJECT="${EMAIL_SUBJECT_PREFIX} ESCALATION: ${service} restart failed on $(hostname)"
            echo "Service '${service}' on $(hostname) failed to restart after ${MAX_RESTART_RETRIES} attempts at ${TIMESTAMP}." | \
                mail -s "$SUBJECT" "$EMAIL_RECIPIENT" 2>/dev/null && \
                log_msg "  EMAIL: Escalation alert sent to ${EMAIL_RECIPIENT}" || \
                log_msg "  EMAIL: Failed to send escalation alert."
        fi
    fi
done

log_msg ""
log_msg "══════════════════════════════════════════════════════════════"
if (( overall_failures > 0 )); then
    log_msg " RESULT: ${overall_failures} service(s) FAILED to recover."
else
    log_msg " RESULT: All critical services are healthy."
fi
log_msg "══════════════════════════════════════════════════════════════"
