#!/usr/bin/env bash
# log_rotation.sh — Delete old logs, compress large ones, prune excess rotated files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.conf"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TARGET_DIR="${SCRIPT_DIR}/${LOG_DIR}"

echo "==============================================================================="
echo "  LOG ROTATION — ${TIMESTAMP}"
echo "==============================================================================="
echo ""

# 1. Delete logs older than retention period
echo "[*] Deleting log files older than ${LOG_RETENTION_DAYS} days..."
deleted_count=0
while IFS= read -r -d '' file; do
    echo "    Deleting: ${file}"
    rm -f "$file"
    ((deleted_count++))
done < <(find "$TARGET_DIR" -type f \( -name "*.log" -o -name "*.log.gz" \) -mtime +${LOG_RETENTION_DAYS} -print0 2>/dev/null)
echo "    Deleted ${deleted_count} file(s)."
echo ""

# 2. Compress large log files
echo "[*] Compressing log files larger than ${LOG_MAX_SIZE_MB} MB..."
compressed_count=0
max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))

while IFS= read -r -d '' file; do
    file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    if (( file_size > max_bytes )); then
        echo "    Compressing: ${file} ($(( file_size / 1024 / 1024 )) MB)"
        gzip -f "$file"
        ((compressed_count++))
    fi
done < <(find "$TARGET_DIR" -type f -name "*.log" -print0 2>/dev/null)
echo "    Compressed ${compressed_count} file(s)."
echo ""

# 3. Enforce max rotated files per log family
echo "[*] Enforcing max ${MAX_ROTATED_FILES} rotated files per log family..."
pruned_count=0

for base_pattern in health_history alerts self_heal security_update; do
    matching_files=()
    while IFS= read -r -d '' f; do
        matching_files+=("$f")
    done < <(find "$TARGET_DIR" -type f -name "${base_pattern}*.gz" -print0 2>/dev/null | sort -z)

    total=${#matching_files[@]}
    if (( total > MAX_ROTATED_FILES )); then
        remove_count=$(( total - MAX_ROTATED_FILES ))
        echo "    ${base_pattern}: ${total} rotated files found, removing oldest ${remove_count}"
        for (( i=0; i<remove_count; i++ )); do
            echo "      Removing: ${matching_files[$i]}"
            rm -f "${matching_files[$i]}"
            ((pruned_count++))
        done
    fi
done
echo "    Pruned ${pruned_count} excess rotated file(s)."
echo ""

# 4. Clean old reports
REPORT_TARGET="${SCRIPT_DIR}/${REPORT_DIR}"
echo "[*] Cleaning old reports (older than ${LOG_RETENTION_DAYS} days)..."
old_reports=0
while IFS= read -r -d '' file; do
    echo "    Deleting: ${file}"
    rm -f "$file"
    ((old_reports++))
done < <(find "$REPORT_TARGET" -type f -mtime +${LOG_RETENTION_DAYS} -print0 2>/dev/null)
echo "    Deleted ${old_reports} old report(s)."
echo ""

echo "==============================================================================="
echo "  LOG ROTATION COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
echo "==============================================================================="
