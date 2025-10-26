#!/bin/bash
# Script: vm_health_check.sh
# Purpose: Check VM health based on CPU, RAM, and Disk usage

# ====== VARIABLES ======
# Explain variable usage:
# CPU_USAGE → Stores current CPU usage percentage
# MEM_USAGE → Stores current Memory (RAM) usage percentage
# DISK_USAGE → Stores the current Disk usage percentage
# HEALTH_THRESHOLD → Maximum allowed usage percentage for a healthy VM

HEALTH_THRESHOLD=60
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')     # Calculate CPU usage
MEM_USAGE=$(free | grep Mem | awk '{print $3/$2 * 100.0}')         # Calculate Memory usage
DISK_USAGE=$(df / | grep / | awk '{print $5}' | sed 's/%//')       # Calculate Disk usage

# ====== DISPLAY DETAILS ======
echo "================= VM HEALTH REPORT ================="
echo "CPU Usage   : ${CPU_USAGE}%"
echo "Memory Usage: ${MEM_USAGE}%"
echo "Disk Usage  : ${DISK_USAGE}%"
echo "===================================================="

# ====== HEALTH CHECK ======
if (( ${CPU_USAGE%.*} < HEALTH_THRESHOLD && ${MEM_USAGE%.*} < HEALTH_THRESHOLD && ${DISK_USAGE%.*} < HEALTH_THRESHOLD )); then
    echo "✅ VM Status : HEALTHY (All usages below ${HEALTH_THRESHOLD}%)"
else
    echo "⚠️  VM Status: UNHEALTHY (One or more usages exceed ${HEALTH_THRESHOLD}%)"
fi
echo "===================================================="
