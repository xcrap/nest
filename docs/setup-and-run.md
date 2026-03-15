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
- `./bin/nestcli`
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
sudo ./bin/nestcli bootstrap test-domain
```

Desktop:

- Open the app
- Go to `Settings`
- Click `Run bootstrap`
- Approve the macOS administrator prompt
- The button changes to a green `Configured` badge when done

This installs:

- `/etc/resolver/test` pointing `.test` queries to `127.0.0.1:5354`
- PF redirects from `80 -> 8080` and `443 -> 8443`

### local HTTPS trust

After FrankenPHP has started once and generated its local CA:

```bash
sudo ./bin/nestcli bootstrap trust-local-ca
```

Or use the desktop app: `Settings` -> `Trust CA`. Shows a green `Trusted` badge when done.

### zsh shell integration

```bash
./bin/nestcli shell integrate --zsh
exec zsh
which php
```

Or use the desktop app: `Dashboard` -> click `Fix` on the `shell-path` doctor check.

Expected path:

```text
$HOME/Library/Application Support/Nest/bin/php
```

## 5. Install runtime binaries

Nest pins the official FrankenPHP macOS arm64 binary and uses its embedded PHP runtime. Install and activate PHP with:

```bash
./bin/nestcli php install 8.5
./bin/nestcli php activate 8.5
```

Or use the desktop app: `Dashboard` -> click `Fix` on the `php-symlink` doctor check, or go to the `PHP` tab.

Start FrankenPHP:

```bash
./bin/nestcli services start
```

## 6. Add and run a site

```bash
mkdir -p ~/Sites/example/public
printf '<?php phpinfo();' > ~/Sites/example/public/index.php

./bin/nestcli site add \
  --name Example \
  --domain example.test \
  --root "$HOME/Sites/example" \
  --type php \
  --php-version 8.5 \
  --https=true

./bin/nestcli site start "$(./bin/nestcli site list | awk 'NR==2 {print $1}')"
```

Note: `--root` points to the project root, not the public folder. The Caddy snippets automatically serve from `{root}/public`.

Site types:
- `--type php` (default): Uses the `php-app` Caddy snippet with PHP error logging.
- `--type laravel`: Uses the `laravel-app` Caddy snippet.

Then open:

- `https://example.test`

## 7. Configuration files

Nest generates a Caddyfile using the same snippet/import pattern used in production FrankenPHP deployments. The config files live in:

```text
~/Library/Application Support/Nest/config/
├── Caddyfile          # Generated - imports snippets and lists sites
├── security.conf      # Editable - HTTP security headers for all sites
├── php.ini            # Editable - PHP runtime settings
├── settings.json
├── sites.json
└── snippets/
    ├── php-app        # Editable - Caddy snippet for PHP sites
    └── laravel-app    # Editable - Caddy snippet for Laravel sites
```

Edit these files via the `Config` tab in the desktop app, or directly on disk. After editing, reload FrankenPHP:

```bash
./bin/nestcli services reload
```

## 8. Inspect health and logs

```bash
./bin/nestcli doctor
./bin/nestcli services status
```

FrankenPHP log file:

```text
~/Library/Application Support/Nest/logs/frankenphp.log
```

## 9. Build the packaged desktop app

```bash
make package
open ./Nest.app
```

The packaged app includes `nestd` and `nesthelper`, and it will auto-start the daemon if the Unix socket is not already present. It also pings the daemon on startup and restarts it if the existing instance is unresponsive.

## 10. Stop development services

```bash
./scripts/stop-dev.sh
./bin/nestcli services stop
```

## Known limits right now

- PHP management is currently pinned to FrankenPHP's embedded `8.5` runtime.
- The packaged app is unsigned, which is expected for this local dev phase.
- Herd should be fully quit before running Nest.
