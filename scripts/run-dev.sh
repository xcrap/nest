#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_VERSION="$(node -p "require('${ROOT_DIR}/package.json').version")"
BUILD_ID="$(date -u +%Y%m%d%H%M%S)-dev"
GO_LDFLAGS="-X github.com/xcrap/nest/daemon/internal/buildinfo.Version=${APP_VERSION} -X github.com/xcrap/nest/daemon/internal/buildinfo.BuildID=${BUILD_ID}"

mkdir -p "${ROOT_DIR}/tmp"

cd "${ROOT_DIR}"

if [[ ! -x "${ROOT_DIR}/bin/nestd" || ! -x "${ROOT_DIR}/bin/nestcli" || ! -x "${ROOT_DIR}/bin/nesthelper" ]]; then
  echo "Building Go binaries..."
  go build -ldflags "${GO_LDFLAGS}" -o ./bin/nestd ./daemon/cmd/nestd
  go build -ldflags "${GO_LDFLAGS}" -o ./bin/nestcli ./daemon/cmd/nestcli
  go build -o ./bin/nesthelper ./helper/cmd/nesthelper
fi

echo "Launching desktop dev UI..."
npm --workspace desktop run dev
