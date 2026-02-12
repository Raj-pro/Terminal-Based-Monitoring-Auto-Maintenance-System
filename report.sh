#!/usr/bin/env bash
###############################################################################
#  report.sh — Daily System Report Generator
#
#  Generates a comprehensive daily report, compresses it, and optionally
#  emails it as an attachment.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.conf"

mkdir -p "${SCRIPT_DIR}/${REPORT_DIR}" "${SCRIPT_DIR}/${LOG_DIR}"

DATE=$(date '+%Y-%m-%d')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_FILE="${SCRIPT_DIR}/${REPORT_DIR}/system_${DATE}.txt"
REPORT_ZIP="${SCRIPT_DIR}/${REPORT_DIR}/system_${DATE}.zip"

# ── Report Header ─────────────────────────────────────────────────────────────

{
echo "==============================================================================="
echo "              DAILY SYSTEM REPORT — $(hostname)"
echo "              Generated: ${TIMESTAMP}"
echo "==============================================================================="
echo ""

# ── 1. System Uptime ──────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 1. SYSTEM UPTIME"
echo "──────────────────────────────────────────────────────────────────────────────"
uptime 2>/dev/null || echo "  Unable to retrieve uptime."
echo ""

# ── 2. CPU Statistics ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 2. CPU STATISTICS"
echo "──────────────────────────────────────────────────────────────────────────────"
if command -v mpstat &>/dev/null; then
    mpstat 1 1 2>/dev/null || echo "  mpstat unavailable."
elif [[ -f /proc/stat ]]; then
    echo "  CPU info from /proc/stat:"
    head -1 /proc/stat
    echo "  Number of CPUs: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo N/A)"
else
    echo "  CPU cores: $(sysctl -n hw.ncpu 2>/dev/null || echo N/A)"
    echo "  CPU usage snapshot:"
    ps -A -o %cpu | awk '{s+=$1} END {printf "  Total: %.1f%%\n", s}'
fi
echo ""

# ── 3. Memory Statistics ──────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 3. MEMORY STATISTICS"
echo "──────────────────────────────────────────────────────────────────────────────"
if command -v free &>/dev/null; then
    free -h 2>/dev/null
else
    echo "  Total Memory: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 )) MB"
    vm_stat 2>/dev/null | head -10
fi
echo ""

# ── 4. Disk Statistics ────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 4. DISK STATISTICS"
echo "──────────────────────────────────────────────────────────────────────────────"
df -h 2>/dev/null
echo ""

# ── 5. Top 5 Processes by CPU ─────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 5. TOP 5 PROCESSES (by CPU usage)"
echo "──────────────────────────────────────────────────────────────────────────────"
ps aux --sort=-%cpu 2>/dev/null | head -6 || \
ps aux -r 2>/dev/null | head -6 || echo "  Unable to list processes."
echo ""

# ── 6. Load Average ───────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 6. LOAD AVERAGE"
echo "──────────────────────────────────────────────────────────────────────────────"
if [[ -f /proc/loadavg ]]; then
    echo "  $(cat /proc/loadavg)"
else
    echo "  $(uptime | awk -F'load average[s]?:' '{print $2}')"
fi
echo ""

# ── 7. Network Statistics ─────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 7. NETWORK STATISTICS"
echo "──────────────────────────────────────────────────────────────────────────────"
if command -v ss &>/dev/null; then
    echo "  Active connections:"
    ss -tun 2>/dev/null | tail -n +2 | wc -l
    echo ""
    echo "  Listening ports:"
    ss -tlnp 2>/dev/null | head -20
elif command -v netstat &>/dev/null; then
    echo "  Active connections: $(netstat -an 2>/dev/null | grep -c ESTABLISHED)"
fi
echo ""

# ── 8. Error Summary ──────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 8. ERROR SUMMARY (System Logs)"
echo "──────────────────────────────────────────────────────────────────────────────"
if command -v journalctl &>/dev/null; then
    echo "  Errors in last 24 hours:"
    journalctl --since "24 hours ago" -p err --no-pager 2>/dev/null | wc -l | xargs echo "  Count:"
    echo ""
    echo "  Recent errors (last 10):"
    journalctl --since "24 hours ago" -p err --no-pager 2>/dev/null | tail -10
elif [[ -f /var/log/syslog ]]; then
    echo "  Errors in syslog:"
    grep -ci "error" /var/log/syslog 2>/dev/null | xargs echo "  Count:" || echo "  Count: 0"
else
    echo "  No system log source available."
fi
echo ""

# ── 9. TCP Statistics ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 9. TCP STATISTICS"
echo "──────────────────────────────────────────────────────────────────────────────"
if [[ -f /proc/net/snmp ]]; then
    grep "^Tcp:" /proc/net/snmp 2>/dev/null
elif command -v netstat &>/dev/null; then
    netstat -s 2>/dev/null | grep -A5 "^Tcp:" | head -10 || \
    netstat -s 2>/dev/null | grep -i tcp | head -10
fi
echo ""

# ── 10. Alert Summary (from logs) ─────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────────────"
echo " 10. ALERT SUMMARY (Today)"
echo "──────────────────────────────────────────────────────────────────────────────"
local_alert_log="${SCRIPT_DIR}/${ALERT_LOG}"
if [[ -f "$local_alert_log" ]]; then
    grep "$DATE" "$local_alert_log" 2>/dev/null | tail -20 || echo "  No alerts today."
else
    echo "  No alert log found."
fi
echo ""

echo "==============================================================================="
echo "                         END OF REPORT"
echo "==============================================================================="

} > "$REPORT_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Report generated: ${REPORT_FILE}"

# ── Compress Report ───────────────────────────────────────────────────────────

if command -v zip &>/dev/null; then
    zip -j "$REPORT_ZIP" "$REPORT_FILE" >/dev/null 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Report compressed: ${REPORT_ZIP}"
elif command -v gzip &>/dev/null; then
    gzip -c "$REPORT_FILE" > "${REPORT_FILE}.gz"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Report compressed: ${REPORT_FILE}.gz"
    REPORT_ZIP="${REPORT_FILE}.gz"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: Neither zip nor gzip available — skipping compression."
fi

# ── Email Report ──────────────────────────────────────────────────────────────

if [[ "${EMAIL_ENABLED}" == "true" ]]; then
    SUBJECT="${EMAIL_SUBJECT_PREFIX} Daily Report - $(hostname) - ${DATE}"
    if command -v mail &>/dev/null; then
        mail -s "$SUBJECT" -A "$REPORT_ZIP" "$EMAIL_RECIPIENT" < "$REPORT_FILE" 2>/dev/null && \
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Report emailed to ${EMAIL_RECIPIENT}" || \
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: Failed to email report."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: mail command not found — skipping email."
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Email not enabled — report saved locally."
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Daily report complete."
