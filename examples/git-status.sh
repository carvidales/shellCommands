#!/usr/bin/env bash
set -euo pipefail
PROJECT="${1:-$HOME/projects/webapp}"
cd "$PROJECT"
printf 'Branch: '
git branch --show-current
printf '\nWorking tree:\n'
git status --short
printf '\nLatest commit:\n'
git log -1 --oneline
