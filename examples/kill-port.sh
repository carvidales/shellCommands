#!/usr/bin/env bash
set -euo pipefail
PORT="${1:-8000}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { echo "Invalid port"; exit 1; }
command -v lsof >/dev/null || { echo "Install lsof first"; exit 1; }
pids=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN || true)
if [[ -z "$pids" ]]; then echo "Port $PORT is free"; exit 0; fi
echo "Requesting graceful shutdown on port $PORT:"
printf '%s\n' "$pids"
while IFS= read -r pid; do kill -TERM "$pid"; done <<< "$pids"
