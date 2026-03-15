#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Nest bootstrap only supports macOS."
  exit 1
fi

check_command() {
  local command="$1"
  local label="$2"

  if command -v "${command}" >/dev/null 2>&1; then
    printf "[pass] %s: %s\n" "${label}" "$(command -v "${command}")"
  else
    printf "[fail] %s is missing.\n" "${label}"
  fi
}

echo "Checking local prerequisites for Nest..."
check_command node "Node.js"
check_command npm "npm"
check_command go "Go"

if xcode-select -p >/dev/null 2>&1; then
  printf "[pass] Xcode Command Line Tools: %s\n" "$(xcode-select -p)"
else
  echo "[fail] Xcode Command Line Tools are missing."
fi

cat <<'EOF'

Install guidance:
- Node.js: https://nodejs.org/
- Go: https://go.dev/dl/
- Xcode Command Line Tools: xcode-select --install

Next steps after all prerequisites pass:
1. npm install --workspace desktop
2. go build ./daemon/cmd/nestd ./daemon/cmd/nestcli ./helper/cmd/nesthelper
3. make dev
EOF

