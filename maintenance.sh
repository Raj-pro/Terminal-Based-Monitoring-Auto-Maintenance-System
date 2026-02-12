#!/usr/bin/env bash
###############################################################################
#  maintenance.sh — Weekly Maintenance Automation
#
#  Performs routine system maintenance:
#    1. System package update
#    2. Temp file cleanup
#    3. Log rotation
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.conf"

mkdir -p "${SCRIPT_DIR}/${LOG_DIR}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "==============================================================================="
echo "  WEEKLY MAINTENANCE — $(hostname)"
echo "  Started: ${TIMESTAMP}"
echo "==============================================================================="
echo ""

# ── 1. System Package Update ─────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════════════════════════"
echo " 1. SYSTEM PACKAGE UPDATE"
echo "══════════════════════════════════════════════════════════════════════════════"

if command -v apt-get &>/dev/null; then
    echo "[*] Detected Debian/Ubuntu — running apt update & upgrade..."
    sudo apt-get update -y 2>&1 | tail -5
    sudo apt-get upgrade -y 2>&1 | tail -10
    sudo apt-get autoremove -y 2>&1 | tail -3
    echo "[✓] Package update complete."
elif command -v yum &>/dev/null; then
    echo "[*] Detected RHEL/CentOS — running yum update..."
    sudo yum update -y 2>&1 | tail -10
    sudo yum autoremove -y 2>&1 | tail -3
    echo "[✓] Package update complete."
elif command -v dnf &>/dev/null; then
    echo "[*] Detected Fedora/RHEL 8+ — running dnf update..."
    sudo dnf update -y 2>&1 | tail -10
    sudo dnf autoremove -y 2>&1 | tail -3
    echo "[✓] Package update complete."
elif command -v pacman &>/dev/null; then
    echo "[*] Detected Arch Linux — running pacman -Syu..."
    sudo pacman -Syu --noconfirm 2>&1 | tail -10
    echo "[✓] Package update complete."
else
    echo "[!] No supported package manager found. Skipping system update."
fi
echo ""

# ── 2. Temporary File Cleanup ─────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════════════════════════"
echo " 2. TEMPORARY FILE CLEANUP"
echo "══════════════════════════════════════════════════════════════════════════════"

tmp_before=$(du -sh /tmp 2>/dev/null | awk '{print $1}' || echo "N/A")
echo "[*] /tmp size before: ${tmp_before}"

# Clean files older than 7 days in /tmp
sudo find /tmp -type f -mtime +7 -delete 2>/dev/null || true
sudo find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true

tmp_after=$(du -sh /tmp 2>/dev/null | awk '{print $1}' || echo "N/A")
echo "[✓] /tmp size after:  ${tmp_after}"

# Clean thumbnail cache
if [[ -d "$HOME/.cache/thumbnails" ]]; then
    rm -rf "$HOME/.cache/thumbnails"/* 2>/dev/null || true
    echo "[✓] Thumbnail cache cleared."
fi

# Clean journal logs (keep last 7 days)
if command -v journalctl &>/dev/null; then
    sudo journalctl --vacuum-time=7d 2>/dev/null | tail -3 || true
    echo "[✓] Journal logs vacuumed (7 days retained)."
fi
echo ""

# ── 3. Log Rotation ──────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════════════════════════"
echo " 3. LOG ROTATION"
echo "══════════════════════════════════════════════════════════════════════════════"

if [[ -x "${SCRIPT_DIR}/log_rotation.sh" ]]; then
    bash "${SCRIPT_DIR}/log_rotation.sh"
else
    echo "[!] log_rotation.sh not found or not executable. Skipping."
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "==============================================================================="
echo "  WEEKLY MAINTENANCE COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
echo "==============================================================================="
