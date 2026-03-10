#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="${ROOT_DIR}/tmp/nestd.pid"

if [[ -f "${PID_FILE}" ]]; then
  kill "$(cat "${PID_FILE}")" 2>/dev/null || true
  rm -f "${PID_FILE}"
  echo "Stopped nestd"
else
  echo "No managed nestd PID file found"
fi

