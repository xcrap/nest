# Developer Setup

This guide is for people coding on Nest itself. If you just want to use the app, go to [docs/user-guide.md](user-guide.md).

## 1. Install prerequisites

```bash
brew install go
./scripts/bootstrap-macos.sh
npm install --workspace desktop
```

## 2. Build the local binaries

```bash
make build
```

This produces:

- `./bin/nestd`
- `./bin/nestctl`
- `./bin/nesthelper`

## 3. Start the app in development

Fast path:

```bash
./scripts/run-dev.sh
```

Manual path:

Terminal 1:

```bash
./bin/nestd
```

Terminal 2:

```bash
npm --workspace desktop run dev
```

## 4. First-time machine bootstrap

### `.test` DNS and port forwarding

CLI:

```bash
sudo ./bin/nestctl bootstrap test-domain
```

Desktop:

- Open the app
- Go to `Settings`
- Click `Install .test Routing`
- Approve the macOS administrator prompt

This installs:

- `/etc/resolver/test` pointing `.test` queries to `127.0.0.1:5354`
- PF redirects from `80 -> 8080` and `443 -> 8443`

### local HTTPS trust

After FrankenPHP has started once and generated its local CA:

```bash
sudo ./bin/nestctl bootstrap trust-local-ca
```

### zsh shell integration

```bash
./bin/nestctl shell integrate --zsh
exec zsh
which php
```

Expected path:

```text
$HOME/Library/Application Support/Nest/bin/php
```

## 5. Install runtime binaries

Nest pins the official FrankenPHP macOS arm64 binary and uses its embedded PHP runtime. Install and activate PHP with:

```bash
./bin/nestctl php install 8.5
./bin/nestctl php activate 8.5
```

Start FrankenPHP:

```bash
./bin/nestctl services start
```

## 6. Add and run a site

```bash
mkdir -p ~/Sites/example/public
printf '<?php phpinfo();' > ~/Sites/example/public/index.php

./bin/nestctl site add \
  --name Example \
  --domain example.test \
  --root "$HOME/Sites/example/public" \
  --php-version 8.5 \
  --https=true

./bin/nestctl site start "$(./bin/nestctl site list | awk 'NR==2 {print $1}')"
```

Then open:

- `https://example.test`

## 7. Inspect health and logs

```bash
./bin/nestctl doctor
./bin/nestctl services status
```

FrankenPHP log file:

```text
~/Library/Application Support/Nest/logs/frankenphp.log
```

## 8. Build the packaged desktop app

```bash
make package
open ./Nest.app
```

The packaged app includes `nestd` and `nesthelper`, and it will auto-start the daemon if the Unix socket is not already present.

## 9. Stop development services

```bash
./scripts/stop-dev.sh
./bin/nestctl services stop
```

## Known limits right now

- PHP management is currently pinned to FrankenPHP's embedded `8.5` runtime.
- The packaged app is unsigned, which is expected for this local dev phase.
- Herd should be fully quit before running Nest.
