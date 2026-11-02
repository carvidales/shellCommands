#!/usr/bin/env bash
set -euo pipefail
# Do not run in Shell Commands: its output would be retained in run history.
openssl rand -base64 24
