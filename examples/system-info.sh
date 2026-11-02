#!/usr/bin/env bash
set -euo pipefail
echo '=== MEMORY ==='
free -h
echo
echo '=== DISK ==='
df -h /
echo
echo '=== UPTIME ==='
uptime -p
echo
echo '=== TOP PROCESSES BY MEMORY ==='
ps -eo pid,comm,%mem --sort=-%mem | head -6
