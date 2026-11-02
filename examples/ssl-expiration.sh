#!/usr/bin/env bash
set -euo pipefail
DOMAIN="${1:-example.com}"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid domain"; exit 1; }
printf 'TLS certificate dates for %s:\n' "$DOMAIN"
openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null |
  openssl x509 -noout -dates
