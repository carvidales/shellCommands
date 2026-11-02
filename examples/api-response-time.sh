#!/usr/bin/env bash
set -euo pipefail
URL="${1:-https://example.com}"
curl --location --silent --show-error --output /dev/null --max-time 15 \
  --write-out 'HTTP: %{http_code}\nDNS: %{time_namelookup}s\nConnection: %{time_connect}s\nTotal: %{time_total}s\n' \
  "$URL"
