#!/usr/bin/env bash
# vm_health_check.sh
# Check the "health" of an Ubuntu VM based on CPU, memory and disk utilization.
# Health rule:
#   If ANY of the three metrics is LESS THAN the threshold (default 60%),
#   the VM is declared "HEALTHY". If ALL three are >= threshold, the VM is "UNHEALTHY".
# Supports:
#   -t THRESHOLD   (default 60)
#   -i INTERVAL    CPU sample interval in seconds (default 1)
#   -e, --explain, explain  Print an explanation for the health decision
#   -h             Show help
#
# Exit codes:
#   0 = healthy
#   1 = unhealthy
#   2 = script error / bad args
set -euo pipefail

THRESHOLD=60
SAMPLE_INTERVAL=1
EXPLAIN=0

usage() {
  cat <<EOF
Usage: $0 [-t THRESHOLD] [-i INTERVAL] [-e|--explain] [explain]
  -t THRESHOLD   Threshold percent (default ${THRESHOLD}). VM is healthy if ANY metric < threshold.
  -i INTERVAL    Sample interval in seconds for CPU calculation (default ${SAMPLE_INTERVAL}).
  -e, --explain  Explain the reason for the health status.
  -h             Show this help.
EOF
}

# Parse options (supports short/long and positional "explain")
while (( "$#" )); do
  case "$1" in
    -t)
      if [ -n "${2-}" ]; then THRESHOLD="$2"; shift 2; else echo "Missing value for -t" >&2; exit 2; fi
      ;;
    -i)
      if [ -n "${2-}" ]; then SAMPLE_INTERVAL="$2"; shift 2; else echo "Missing value for -i" >&2; exit 2; fi
      ;;
    -e|--explain|explain)
      EXPLAIN=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1" >&2; usage; exit 2
      ;;
    *) # positional (ignore other positional args except "explain" which is handled above)
      shift
      ;;
  esac
done

# Validate numeric args
if ! printf '%s' "$THRESHOLD" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
  echo "Invalid threshold: $THRESHOLD" >&2
  exit 2
fi
if ! printf '%s' "$SAMPLE_INTERVAL" | grep -Eq '^[0-9]+$'; then
  echo "Invalid sample interval: $SAMPLE_INTERVAL" >&2
  exit 2
fi

# Compute CPU usage (%) by sampling /proc/stat
get_cpu_usage() {
  # read first snapshot
  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  idle1=$((idle + iowait))
  nonidle1=$((user + nice + system + irq + softirq + steal))
  total1=$((idle1 + nonidle1))

  sleep "$SAMPLE_INTERVAL"

  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  idle2=$((idle + iowait))
  nonidle2=$((user + nice + system + irq + softirq + steal))
  total2=$((idle2 + nonidle2))

  diff_total=$((total2 - total1))
  diff_idle=$((idle2 - idle1))

  if [ "$diff_total" -le 0 ]; then
    printf "0.0"
    return
  fi

  # usage = (diff_total - diff_idle) / diff_total * 100
  awk -v dt="$diff_total" -v di="$diff_idle" 'BEGIN { printf "%.1f", (dt - di) / dt * 100 }'
}

# Memory used percent using /proc/meminfo (MemAvailable)
get_mem_usage() {
  mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo || echo "")
  mem_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo || echo "")

  if [ -z "$mem_total_kb" ] || [ -z "$mem_avail_kb" ] || [ "$mem_total_kb" -le 0 ]; then
    printf "0.0"
    return
  fi

  used_kb=$((mem_total_kb - mem_avail_kb))
  awk -v used="$used_kb" -v tot="$mem_total_kb" 'BEGIN { printf "%.1f", used / tot * 100 }'
}

# Disk usage: return highest percent used and a newline-separated list of mount:percent
get_disk_usage_and_list() {
  # df -P for portable output; exclude tmpfs and devtmpfs which are common on Ubuntu
  # Output lines: Filesystem 1024-blocks Used Available Capacity Mounted on
  df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 {print $6 " " $5}' | while read -r mount cap; do
    # cap like "12%"; strip %
    capnum = cap
    gsub(/%/,"",cap)
    printf "%s:%s\n" "$mount" "$cap"
  done
}

# More portable: build disk list in bash by parsing df
build_disk_list() {
  disk_lines=$(df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 {print $6 "|" $5}')
  # if df returns nothing (rare), return defaults
  if [ -z "$disk_lines" ]; then
    echo "0.0"
    echo ""
    return
  fi

  max=0
  detail=""
  while IFS= read -r line; do
    mount="${line%%|*}"
    cap="${line##*|}"
    cap="${cap%\%}"
    # ensure numeric
    if printf '%s' "$cap" | grep -Eq '^[0-9]+$'; then
      # track max
      if [ "$cap" -gt "$max" ]; then max=$cap; fi
      detail+="${mount}:${cap}%\n"
    fi
  done <<EOF
$disk_lines
EOF

  # print max as float, then the details
  printf "%s.0\n" "$max"
  # echo -e for expanding \n but keep portable: use awk to print the detail properly
  if [ -n "$detail" ]; then
    # remove trailing \n
    printf "%b" "$detail"
  fi
}

# call metric functions
cpu=$(get_cpu_usage)
mem=$(get_mem_usage)

# get disk max and list
# build_disk_list prints first line = max, subsequent lines = mount:percent%
disk_tmp=$(mktemp)
trap 'rm -f "$disk_tmp"' EXIT
build_disk_list > "$disk_tmp" || true
disk=$(sed -n '1p' "$disk_tmp" || echo "0.0")
disk_list=$(sed -n '2,$p' "$disk_tmp" || true)

# Print metrics
printf "CPU Usage:    %s%%\n" "$cpu"
printf "Memory Usage: %s%%\n" "$mem"
printf "Disk Usage:   %s%% (highest across mounts)\n" "$disk"
printf "Threshold:    %s%%\n" "$THRESHOLD"

# Compare floats with awk
cpu_lt_threshold=$(awk -v v="$cpu" -v t="$THRESHOLD" 'BEGIN { print (v < t) ? 1 : 0 }')
mem_lt_threshold=$(awk -v v="$mem" -v t="$THRESHOLD" 'BEGIN { print (v < t) ? 1 : 0 }')
disk_lt_threshold=$(awk -v v="$disk" -v t="$THRESHOLD" 'BEGIN { print (v < t) ? 1 : 0 }')

# Decide health
if [ "$cpu_lt_threshold" -eq 1 ] || [ "$mem_lt_threshold" -eq 1 ] || [ "$disk_lt_threshold" -eq 1 ]; then
  state="HEALTHY"
  exit_code=0
else
  state="UNHEALTHY"
  exit_code=1
fi

echo "VM STATE: $state"

# If explain requested, print the reasoning
if [ "$EXPLAIN" -eq 1 ]; then
  echo
  echo "Explanation:"
  if [ "$state" = "HEALTHY" ]; then
    echo "- At least one metric is below the threshold (${THRESHOLD}%). The following metric(s) are below threshold:"
    if [ "$cpu_lt_threshold" -eq 1 ]; then
      echo "  * CPU:    ${cpu}% < ${THRESHOLD}%  --> CPU load is within limits."
    else
      echo "  * CPU:    ${cpu}% >= ${THRESHOLD}%  --> CPU is high."
    fi
    if [ "$mem_lt_threshold" -eq 1 ]; then
      echo "  * Memory: ${mem}% < ${THRESHOLD}%  --> Memory usage is within limits."
    else
      echo "  * Memory: ${mem}% >= ${THRESHOLD}%  --> Memory usage is high."
    fi
    if [ "$disk_lt_threshold" -eq 1 ]; then
      echo "  * Disk:   ${disk}% < ${THRESHOLD}%  --> Disk usage (highest mount) is within limits."
      if [ -n "$disk_list" ]; then
        echo "    Detailed mount usages (mount:used%):"
        printf '      %s\n' "$disk_list"
      fi
    else
      echo "  * Disk:   ${disk}% >= ${THRESHOLD}%  --> Disk usage (highest mount) is high."
      if [ -n "$disk_list" ]; then
        echo "    Detailed mount usages (mount:used%):"
        printf '      %s\n' "$disk_list"
      fi
    fi
    # indicate which metric(s) actually made the VM healthy
    echo
    echo -n "Reason: "
    reasons=()
    [ "$cpu_lt_threshold" -eq 1 ] && reasons+=("CPU (${cpu}%) below threshold")
    [ "$mem_lt_threshold" -eq 1 ] && reasons+=("Memory (${mem}%) below threshold")
    [ "$disk_lt_threshold" -eq 1 ] && reasons+=("Disk (${disk}%) below threshold")
    # join reasons with '; '
    sep=""
    for r in "${reasons[@]}"; do
      printf "%s%s" "$sep" "$r"
      sep="; "
    done
    echo
  else
    # UNHEALTHY
    echo "- All three metrics are at or above the threshold (${THRESHOLD}%), so the VM is considered UNHEALTHY."
    echo "  Metric values:"
    echo "  * CPU:    ${cpu}% (>= ${THRESHOLD}%)"
    echo "  * Memory: ${mem}% (>= ${THRESHOLD}%)"
    echo "  * Disk:   ${disk}% (highest mount) (>= ${THRESHOLD}%)"
    if [ -n "$disk_list" ]; then
      echo "  Detailed mount usages (mount:used%):"
      printf '    %s\n' "$disk_list"
    fi
    echo
    echo "Possible next steps (Ubuntu):"
    echo "  - Investigate top CPU consumers: run 'top' or 'htop' or 'ps aux --sort=-%cpu | head -n 10'."
    echo "  - Check memory usage and cached/buffered memory: 'free -h' and 'ps aux --sort=-%mem | head -n 10'."
    echo "  - Identify large files or clean package caches to free disk: 'du -sh /*' or check '/var/log', '/var/lib/apt/lists', '/var/cache/apt/archives'."
    echo "  - Consider resizing the VM (more vCPU / RAM / disk) or reducing workload."
  fi
fi

exit "$exit_code"