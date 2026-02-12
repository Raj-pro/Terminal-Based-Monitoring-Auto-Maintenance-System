#!/usr/bin/env bash
# monitor.sh — Real-time system monitoring dashboard
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.conf"

mkdir -p "${SCRIPT_DIR}/${LOG_DIR}" "${SCRIPT_DIR}/${REPORT_DIR}"

# ANSI colors
RST="\033[0m"
BOLD="\033[1m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
BLUE="\033[1;34m"
WHITE="\033[1;37m"
BG_RED="\033[41m"
BG_YELLOW="\033[43m"
BG_GREEN="\033[42m"

# Return color based on threshold comparison
color_by_threshold() {
    local val="$1" warn="$2" crit="$3"
    if (( $(echo "$val >= $crit" | bc -l 2>/dev/null || echo 0) )); then
        echo -ne "${RED}"
    elif (( $(echo "$val >= $warn" | bc -l 2>/dev/null || echo 0) )); then
        echo -ne "${YELLOW}"
    else
        echo -ne "${GREEN}"
    fi
}

# Return status label (CRITICAL/WARNING/NORMAL)
status_label() {
    local val="$1" warn="$2" crit="$3"
    if (( $(echo "$val >= $crit" | bc -l 2>/dev/null || echo 0) )); then
        echo -ne "${BG_RED}${WHITE} CRITICAL ${RST}"
    elif (( $(echo "$val >= $warn" | bc -l 2>/dev/null || echo 0) )); then
        echo -ne "${BG_YELLOW}${WHITE} WARNING  ${RST}"
    else
        echo -ne "${BG_GREEN}${WHITE}  NORMAL  ${RST}"
    fi
}

# Draw a horizontal bar ████░░░░░░
draw_bar() {
    local pct="$1" width=30
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty;  i++)); do bar+="░"; done
    echo -n "$bar"
}

divider() {
    printf "${BLUE}%0.s─" {1..72}
    printf "${RST}\n"
}

header() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║       ⚙  LINUX SYSTEM MONITORING DASHBOARD  ⚙                        ║"
    echo "║       $(date '+%Y-%m-%d %H:%M:%S')                                         ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${RST}"
}

# CPU usage (normalized to 0-100% on macOS)
get_cpu_usage() {
    if [[ -f /proc/stat ]]; then
        local cpu1 cpu2
        cpu1=($(head -1 /proc/stat))
        sleep 1
        cpu2=($(head -1 /proc/stat))
        local idle1=${cpu1[4]} idle2=${cpu2[4]}
        local total1=0 total2=0
        for i in "${cpu1[@]:1}"; do total1=$((total1 + i)); done
        for i in "${cpu2[@]:1}"; do total2=$((total2 + i)); done
        local diff_total=$((total2 - total1))
        local diff_idle=$((idle2 - idle1))
        if (( diff_total > 0 )); then
            echo "scale=1; (1 - $diff_idle / $diff_total) * 100" | bc -l
        else
            echo "0.0"
        fi
    else
        local ncpu
        ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
        ps -A -o %cpu | awk -v cores="$ncpu" '{s+=$1} END {printf "%.1f", s/cores}'
    fi
}

# Memory usage — returns pct|used_mb|total_mb
get_memory_usage() {
    if command -v free &>/dev/null; then
        free | awk '/Mem:/ {printf "%.1f|%d|%d", $3/$2*100, $3/1024, $2/1024}'
    elif command -v vm_stat &>/dev/null; then
        local vmstat_out
        vmstat_out=$(vm_stat 2>/dev/null)
        local page_size
        page_size=$(echo "$vmstat_out" | head -1 | grep -oE '[0-9]+' || echo 4096)
        [[ -z "$page_size" ]] && page_size=4096

        local pages_active pages_wired
        pages_active=$(echo "$vmstat_out" | awk '/Pages active/ {gsub(/[^0-9]/,"",$NF); print $NF}' || echo 0)
        pages_wired=$(echo "$vmstat_out" | awk '/Pages wired down/ {gsub(/[^0-9]/,"",$NF); print $NF}' || echo 0)
        [[ -z "$pages_active" ]] && pages_active=0
        [[ -z "$pages_wired" ]] && pages_wired=0

        local total
        total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        local total_mb=$((total / 1024 / 1024))
        [[ "$total_mb" -eq 0 ]] && { echo "0.0|0|0"; return; }

        local used_pages=$(( pages_active + pages_wired ))
        local used_mb=$(( used_pages * page_size / 1024 / 1024 ))
        local pct
        pct=$(echo "scale=1; $used_mb * 100 / $total_mb" | bc -l 2>/dev/null || echo "0.0")
        echo "${pct}|${used_mb}|${total_mb}"
    else
        echo "0.0|0|0"
    fi
}

# Disk usage for root partition
get_disk_usage() {
    df -h / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); printf "%s|%s|%s|%s", $5, $3, $2, $4}'
}

# Disk I/O latency
get_disk_io() {
    if [[ -f /proc/diskstats ]]; then
        local val
        val=$(iostat -d 1 2 2>/dev/null | awk '/^[a-z]/ && NR>3 {print $NF; exit}')
        echo "${val:-N/A}"
    elif command -v iostat &>/dev/null; then
        local val
        val=$(iostat -d -c 2 -w 1 2>/dev/null | awk 'NR==4 {print $1}')
        echo "${val:-0} KB/t"
    else
        echo "N/A"
    fi
}

# Network speed — returns dl_kb|ul_kb|interface
get_network_speed() {
    if [[ -d /sys/class/net ]]; then
        local iface
        iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")
        local rx1 tx1 rx2 tx2
        rx1=$(cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null || echo 0)
        tx1=$(cat /sys/class/net/${iface}/statistics/tx_bytes 2>/dev/null || echo 0)
        sleep 1
        rx2=$(cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null || echo 0)
        tx2=$(cat /sys/class/net/${iface}/statistics/tx_bytes 2>/dev/null || echo 0)
        local dl=$(( (rx2 - rx1) / 1024 ))
        local ul=$(( (tx2 - tx1) / 1024 ))
        echo "${dl}|${ul}|${iface}"
    else
        local iface="en0"
        local rx1 tx1 rx2 tx2
        rx1=$(netstat -ib 2>/dev/null | awk '/^en0[[:space:]]/ && $7 ~ /^[0-9]+$/ {print $7; exit}')
        tx1=$(netstat -ib 2>/dev/null | awk '/^en0[[:space:]]/ && $7 ~ /^[0-9]+$/ {print $10; exit}')
        rx1=${rx1:-0}; tx1=${tx1:-0}
        sleep 1
        rx2=$(netstat -ib 2>/dev/null | awk '/^en0[[:space:]]/ && $7 ~ /^[0-9]+$/ {print $7; exit}')
        tx2=$(netstat -ib 2>/dev/null | awk '/^en0[[:space:]]/ && $7 ~ /^[0-9]+$/ {print $10; exit}')
        rx2=${rx2:-0}; tx2=${tx2:-0}
        local dl=$(( (rx2 - rx1) / 1024 ))
        local ul=$(( (tx2 - tx1) / 1024 ))
        (( dl < 0 )) && dl=0
        (( ul < 0 )) && ul=0
        echo "${dl}|${ul}|${iface}"
    fi
}

# Active network connections count
get_network_connections() {
    if command -v ss &>/dev/null; then
        ss -tun 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
    else
        local count
        count=$(netstat -an 2>/dev/null | grep -c ESTABLISHED 2>/dev/null) || count=0
        echo "${count:-0}"
    fi
}

# System uptime string
get_uptime_info() {
    uptime | sed 's/.*up //' | sed 's/,.*load.*//' | xargs
}

# Load average — returns l1|l5|l15
get_load_average() {
    if [[ -f /proc/loadavg ]]; then
        awk '{print $1"|"$2"|"$3}' /proc/loadavg
    else
        local raw
        raw=$(uptime 2>/dev/null | sed 's/.*load average[s]*: *//' | tr -d ',')
        local l1 l5 l15
        l1=$(echo "$raw" | awk '{print $1}')
        l5=$(echo "$raw" | awk '{print $2}')
        l15=$(echo "$raw" | awk '{print $3}')
        echo "${l1:-0}|${l5:-0}|${l15:-0}"
    fi
}

# System error count (last 5 min)
get_error_rate() {
    if command -v journalctl &>/dev/null; then
        local count
        count=$(journalctl --since "5 min ago" -p err --no-pager 2>/dev/null | wc -l | tr -d ' ') || count=0
        echo "${count:-0}"
    elif [[ -f /var/log/syslog ]]; then
        local count
        count=$(grep -ci "error" /var/log/syslog 2>/dev/null) || count=0
        echo "${count:-0}"
    else
        echo "N/A"
    fi
}

# Top 5 processes by CPU
get_top_processes() {
    if ps -eo user,pid,pcpu,pmem,comm --sort=-pcpu &>/dev/null 2>&1; then
        ps -eo user=USER,pid=PID,pcpu=%CPU,pmem=%MEM,comm=COMMAND --sort=-pcpu 2>/dev/null | head -6 | tail -5
    else
        ps -eo user=USER,pid=PID,pcpu=%CPU,pmem=%MEM,comm=COMMAND -r 2>/dev/null | head -6 | tail -5
    fi
}

# TCP retransmission count
get_tcp_retransmissions() {
    if [[ -f /proc/net/snmp ]]; then
        local val
        val=$(awk '/^Tcp:/ && !/Tcp:.*Rto/ {print $13}' /proc/net/snmp 2>/dev/null)
        echo "${val:-0}"
    elif command -v netstat &>/dev/null; then
        local val
        val=$(netstat -s 2>/dev/null | awk '/retransmit/ {print $1; exit}')
        echo "${val:-N/A}"
    else
        echo "N/A"
    fi
}

# Run alerts.sh in background
trigger_alerts() {
    local cpu="$1" mem="$2" disk="$3" load="$4"
    bash "${SCRIPT_DIR}/alerts.sh" "$cpu" "$mem" "$disk" "$load" &
}

# Log health snapshot at configured interval
LAST_HEALTH_LOG=0

log_health() {
    local now
    now=$(date +%s)
    if (( now - LAST_HEALTH_LOG >= HEALTH_LOG_INTERVAL )); then
        local ts cpu mem disk load
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        cpu="$1"; mem="$2"; disk="$3"; load="$4"
        echo "${ts} | CPU: ${cpu}% | MEM: ${mem}% | DISK: ${disk}% | LOAD: ${load}" \
            >> "${SCRIPT_DIR}/${HEALTH_LOG}"
        LAST_HEALTH_LOG=$now
    fi
}

# Main dashboard renderer
render_dashboard() {
    header

    # CPU
    local cpu
    cpu=$(get_cpu_usage)
    local cpu_int=${cpu%.*}
    [[ -z "$cpu_int" ]] && cpu_int=0
    echo -e " ${BOLD}${WHITE}CPU USAGE${RST}"
    divider
    color_by_threshold "$cpu_int" "$CPU_WARN" "$CPU_CRIT"
    printf "  Usage: %5s%%  [$(draw_bar $cpu_int)]  " "$cpu"
    status_label "$cpu_int" "$CPU_WARN" "$CPU_CRIT"
    echo -e "${RST}\n"

    # Memory
    local mem_info mem_pct mem_used mem_total
    mem_info=$(get_memory_usage)
    mem_pct=$(echo "$mem_info"  | cut -d'|' -f1)
    mem_used=$(echo "$mem_info" | cut -d'|' -f2)
    mem_total=$(echo "$mem_info"| cut -d'|' -f3)
    local mem_int=${mem_pct%.*}
    [[ -z "$mem_int" ]] && mem_int=0
    echo -e " ${BOLD}${WHITE}MEMORY USAGE${RST}"
    divider
    color_by_threshold "$mem_int" "$MEMORY_WARN" "$MEMORY_CRIT"
    printf "  Usage: %5s%%  [$(draw_bar $mem_int)]  " "$mem_pct"
    status_label "$mem_int" "$MEMORY_WARN" "$MEMORY_CRIT"
    echo -e "${RST}"
    echo -e "  ${CYAN}Used: ${mem_used} MB / Total: ${mem_total} MB${RST}\n"

    # Disk
    local disk_info disk_pct disk_used disk_size disk_avail
    disk_info=$(get_disk_usage)
    disk_pct=$(echo "$disk_info"  | cut -d'|' -f1)
    disk_used=$(echo "$disk_info" | cut -d'|' -f2)
    disk_size=$(echo "$disk_info" | cut -d'|' -f3)
    disk_avail=$(echo "$disk_info"| cut -d'|' -f4)
    local disk_int=${disk_pct%.*}
    [[ -z "$disk_int" ]] && disk_int=0
    echo -e " ${BOLD}${WHITE}DISK USAGE (/)${RST}"
    divider
    color_by_threshold "$disk_int" "$DISK_WARN" "$DISK_CRIT"
    printf "  Usage: %5s%%  [$(draw_bar $disk_int)]  " "${disk_pct}"
    status_label "$disk_int" "$DISK_WARN" "$DISK_CRIT"
    echo -e "${RST}"
    echo -e "  ${CYAN}Used: ${disk_used} / Size: ${disk_size} / Avail: ${disk_avail}${RST}\n"

    # Disk I/O
    local io_latency
    io_latency=$(get_disk_io)
    echo -e " ${BOLD}${WHITE}DISK I/O LATENCY${RST}"
    divider
    echo -e "  ${MAGENTA}Avg I/O: ${io_latency}${RST}\n"

    # Network speed
    local net_info net_dl net_ul net_if
    net_info=$(get_network_speed)
    net_dl=$(echo "$net_info" | cut -d'|' -f1)
    net_ul=$(echo "$net_info" | cut -d'|' -f2)
    net_if=$(echo "$net_info" | cut -d'|' -f3)
    echo -e " ${BOLD}${WHITE}NETWORK SPEED (${net_if})${RST}"
    divider
    echo -e "  ${GREEN}↓ Download: ${net_dl} KB/s    ↑ Upload: ${net_ul} KB/s${RST}\n"

    # Network connections
    local net_conn
    net_conn=$(get_network_connections)
    echo -e " ${BOLD}${WHITE}NETWORK CONNECTIONS${RST}"
    divider
    echo -e "  ${CYAN}Active connections: ${net_conn}${RST}\n"

    # Uptime & load
    local uptime_str load_info load1 load5 load15
    uptime_str=$(get_uptime_info)
    load_info=$(get_load_average)
    load1=$(echo "$load_info" | cut -d'|' -f1 | xargs)
    load5=$(echo "$load_info" | cut -d'|' -f2 | xargs)
    load15=$(echo "$load_info" | cut -d'|' -f3 | xargs)
    local load_int=${load1%.*}
    [[ -z "$load_int" ]] && load_int=0
    echo -e " ${BOLD}${WHITE}UPTIME & LOAD AVERAGE${RST}"
    divider
    echo -e "  ${CYAN}Uptime: ${uptime_str}${RST}"
    color_by_threshold "$load_int" "$LOAD_WARN" "$LOAD_CRIT"
    printf "  Load Avg (1/5/15): %s / %s / %s  " "$load1" "$load5" "$load15"
    status_label "$load_int" "$LOAD_WARN" "$LOAD_CRIT"
    echo -e "${RST}\n"

    # Error rate
    local err_rate
    err_rate=$(get_error_rate)
    echo -e " ${BOLD}${WHITE}SYSTEM ERROR RATE (last 5 min)${RST}"
    divider
    echo -e "  ${MAGENTA}Errors: ${err_rate}${RST}\n"

    # TCP retransmissions
    local tcp_retrans
    tcp_retrans=$(get_tcp_retransmissions)
    echo -e " ${BOLD}${WHITE}TCP RETRANSMISSIONS${RST}"
    divider
    echo -e "  ${MAGENTA}Total retransmits: ${tcp_retrans}${RST}\n"

    # Top 5 processes
    echo -e " ${BOLD}${WHITE}TOP 5 PROCESSES (by CPU)${RST}"
    divider
    printf "  ${CYAN}%-12s %-7s %-6s %-6s %-30s${RST}\n" "USER" "PID" "%CPU" "%MEM" "COMMAND"
    get_top_processes | while read -r p_user p_pid p_cpu p_mem p_cmd; do
        local short_cmd
        short_cmd=$(basename "$p_cmd" 2>/dev/null || echo "$p_cmd")
        short_cmd="${short_cmd:0:30}"
        printf "  ${WHITE}%-12s %-7s %-6s %-6s %-30s${RST}\n" "$p_user" "$p_pid" "$p_cpu" "$p_mem" "$short_cmd"
    done
    echo ""

    # Footer
    divider
    echo -e " ${BOLD}${CYAN}Refreshing every ${REFRESH_INTERVAL}s  |  Press Ctrl+C to exit${RST}"
    echo ""

    trigger_alerts "$cpu_int" "$mem_int" "$disk_int" "$load1"
    log_health "$cpu_int" "$mem_int" "$disk_int" "$load1"
}

# Main loop
trap "echo -e '\n${GREEN}Dashboard stopped.${RST}'; exit 0" SIGINT SIGTERM

echo -e "${CYAN}Starting System Monitor Dashboard...${RST}"
while true; do
    render_dashboard
    sleep "${REFRESH_INTERVAL}"
done
