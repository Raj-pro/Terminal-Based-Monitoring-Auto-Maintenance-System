#!/usr/bin/env bash
###############################################################################
#  setup_cron.sh — Install Cron Jobs for Automated Monitoring
#
#  Sets up the following cron schedule:
#    */5 * * * *    — Health logging (every 5 minutes)
#    59 23 * * *    — Daily report at 11:59 PM
#    0 0 * * *      — Log rotation at midnight
#    0 2 * * 0      — Weekly maintenance Sunday 2 AM
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  CRON JOB INSTALLER — Linux Monitoring System               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Define cron entries ───────────────────────────────────────────────────────
CRON_MARKER="# LINUX-MONITORING-SYSTEM"

CRON_ENTRIES=$(cat <<EOF
${CRON_MARKER}-START
# Health history logging — every 5 minutes
*/5 * * * * bash ${SCRIPT_DIR}/alerts.sh \$(bash -c 'source ${SCRIPT_DIR}/monitor.sh --metrics-only 2>/dev/null || echo "0 0 0 0"') >> ${SCRIPT_DIR}/logs/cron_health.log 2>&1

# Daily report — 11:59 PM every day
59 23 * * * bash ${SCRIPT_DIR}/report.sh >> ${SCRIPT_DIR}/logs/cron_report.log 2>&1

# Log rotation — midnight every day
0 0 * * * bash ${SCRIPT_DIR}/log_rotation.sh >> ${SCRIPT_DIR}/logs/cron_rotation.log 2>&1

# Weekly maintenance — Sunday 2:00 AM
0 2 * * 0 bash ${SCRIPT_DIR}/maintenance.sh >> ${SCRIPT_DIR}/logs/cron_maintenance.log 2>&1

# Security updates — Sunday 3:00 AM (after maintenance)
0 3 * * 0 bash ${SCRIPT_DIR}/security_update.sh >> ${SCRIPT_DIR}/logs/cron_security.log 2>&1

# Self-healing service check — every 5 minutes
*/5 * * * * bash ${SCRIPT_DIR}/self_heal.sh >> ${SCRIPT_DIR}/logs/cron_selfheal.log 2>&1
${CRON_MARKER}-END
EOF
)

# ── Install or Update ─────────────────────────────────────────────────────────

# Get existing crontab (if any)
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

# Remove old entries if they exist
if echo "$EXISTING_CRON" | grep -q "${CRON_MARKER}-START"; then
    echo "[*] Removing previous monitoring cron entries..."
    CLEAN_CRON=$(echo "$EXISTING_CRON" | sed "/${CRON_MARKER}-START/,/${CRON_MARKER}-END/d")
else
    CLEAN_CRON="$EXISTING_CRON"
fi

# Install new entries
echo "$CLEAN_CRON" | { cat; echo ""; echo "$CRON_ENTRIES"; } | crontab -

echo "[✓] Cron jobs installed successfully!"
echo ""
echo "Installed schedule:"
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  */5 * * * *   Health logging & Self-heal check             │"
echo "  │  59 23 * * *   Daily system report                          │"
echo "  │  0  0  * * *   Log rotation                                 │"
echo "  │  0  2  * * 0   Weekly maintenance (Sunday 2 AM)             │"
echo "  │  0  3  * * 0   Security updates   (Sunday 3 AM)             │"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
echo "To verify:  crontab -l"
echo "To remove:  crontab -l | sed '/${CRON_MARKER}-START/,/${CRON_MARKER}-END/d' | crontab -"
