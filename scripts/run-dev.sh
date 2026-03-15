#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="${ROOT_DIR}/tmp/nestd.pid"
SOCKET_PATH="${HOME}/Library/Application Support/Nest/run/nest.sock"

mkdir -p "${ROOT_DIR}/tmp"

cd "${ROOT_DIR}"

if [[ ! -x "${ROOT_DIR}/bin/nestd" || ! -x "${ROOT_DIR}/bin/nestcli" || ! -x "${ROOT_DIR}/bin/nesthelper" ]]; then
  echo "Building Go binaries..."
  go build -o ./bin/nestd ./daemon/cmd/nestd
  go build -o ./bin/nestcli ./daemon/cmd/nestcli
  go build -o ./bin/nesthelper ./helper/cmd/nesthelper
fi

if [[ ! -S "${SOCKET_PATH}" ]]; then
  echo "Starting nestd..."
  "${ROOT_DIR}/bin/nestd" > "${ROOT_DIR}/tmp/nestd.log" 2>&1 &
  echo $! > "${PID_FILE}"
  sleep 1
fi

echo "Launching desktop dev UI..."
npm --workspace desktop run dev

