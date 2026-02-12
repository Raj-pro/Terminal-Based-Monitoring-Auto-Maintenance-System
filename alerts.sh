#!/usr/bin/env bash
###############################################################################
#  alerts.sh — Threshold-Based Alerting System
#
#  Usage: bash alerts.sh <cpu%> <mem%> <disk%> <load>
#  Compares metrics against config thresholds, logs breaches, sends email.
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.conf"

mkdir -p "${SCRIPT_DIR}/${LOG_DIR}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
ALERT_FILE="${SCRIPT_DIR}/${ALERT_LOG}"

# ── Input ─────────────────────────────────────────────────────────────────────
CPU="${1:-0}"
MEM="${2:-0}"
DISK="${3:-0}"
LOAD="${4:-0}"

ALERTS_TRIGGERED=()

# ── Compare Metrics ───────────────────────────────────────────────────────────

check_threshold() {
    local metric_name="$1" value="$2" warn="$3" crit="$4"
    local level=""

    if (( $(echo "$value >= $crit" | bc -l 2>/dev/null || echo 0) )); then
        level="CRITICAL"
    elif (( $(echo "$value >= $warn" | bc -l 2>/dev/null || echo 0) )); then
        level="WARNING"
    fi

    if [[ -n "$level" ]]; then
        local msg="[${TIMESTAMP}] ${level}: ${metric_name} = ${value} (warn=${warn}, crit=${crit})"
        echo "$msg" >> "$ALERT_FILE"
        ALERTS_TRIGGERED+=("$msg")
    fi
}

check_threshold "CPU"    "$CPU"  "$CPU_WARN"    "$CPU_CRIT"
check_threshold "MEMORY" "$MEM"  "$MEMORY_WARN" "$MEMORY_CRIT"
check_threshold "DISK"   "$DISK" "$DISK_WARN"   "$DISK_CRIT"
check_threshold "LOAD"   "$LOAD" "$LOAD_WARN"   "$LOAD_CRIT"

# ── Send Email (if enabled and alerts exist) ──────────────────────────────────

send_email_alert() {
    if [[ "${EMAIL_ENABLED}" != "true" ]]; then
        return
    fi

    if ! command -v mail &>/dev/null && ! command -v sendmail &>/dev/null; then
        echo "[${TIMESTAMP}] EMAIL_SKIP: mail command not found, skipping email alert." >> "$ALERT_FILE"
        return
    fi

    local subject="${EMAIL_SUBJECT_PREFIX} System Alert - $(hostname) - ${TIMESTAMP}"
    local body=""
    for alert in "${ALERTS_TRIGGERED[@]}"; do
        body+="${alert}\n"
    done

    if command -v mail &>/dev/null; then
        echo -e "$body" | mail -s "$subject" "$EMAIL_RECIPIENT"
    elif command -v sendmail &>/dev/null; then
        {
            echo "Subject: ${subject}"
            echo "From: ${EMAIL_FROM}"
            echo "To: ${EMAIL_RECIPIENT}"
            echo ""
            echo -e "$body"
        } | sendmail "$EMAIL_RECIPIENT"
    fi

    echo "[${TIMESTAMP}] EMAIL_SENT: Alert email sent to ${EMAIL_RECIPIENT}" >> "$ALERT_FILE"
}

if [[ ${#ALERTS_TRIGGERED[@]} -gt 0 ]]; then
    send_email_alert
fi
