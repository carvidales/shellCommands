#!/usr/bin/env bash
set -euo pipefail
PROJECT="${1:-$HOME}"
[[ -d "$PROJECT" ]] || { echo "Directory not found: $PROJECT"; exit 1; }
find "$PROJECT" -type f -printf '%s %p\n' 2>/dev/null |
  sort -nr |
  head -10 |
  numfmt --field=1 --to=iec || true
