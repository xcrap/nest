# Architecture

## Components

### Go daemon and CLI

The daemon owns local state, exposes a Unix socket HTTP API, runs the `.test` DNS responder, supervises FrankenPHP, and generates Caddy configuration. `nestcli` is a thin client over the same socket API with a few direct filesystem helpers for bootstrap-friendly commands.

### Electron desktop app

The GUI is a control plane only. It talks to the daemon through Electron IPC in the main process, which bridges renderer actions to the Unix socket API. On startup, it pings the daemon and restarts it if the socket is stale.

### Privileged helper

The helper is intentionally small and macOS-only. It performs one-time bootstrap tasks:

- create `/etc/resolver/test` pointing to `127.0.0.1` port `5354`
- install PF redirection from `80 -> 8080` and `443 -> 8443`
- reserve a place for CA trust/bootstrap flows

## Traffic model

- `*.test` DNS resolution goes to the daemon's local DNS server on `127.0.0.1:5354`
- PF redirects browser traffic on `80/443` to FrankenPHP on `8080/8443`
- FrankenPHP/Caddy terminates TLS and serves PHP/static files for running sites

## Caddy configuration

The Caddyfile uses the same snippet/import pattern as production FrankenPHP deployments:

```text
import snippets/*

import php-app project.test /Users/me/project
import laravel-app laravel.test /Users/me/laravel
```

### Site types

- **php** (`php-app` snippet): For custom PHP websites. Includes `PHP_INI_log_errors` in the `php_server` block.
- **laravel** (`laravel-app` snippet): For Laravel projects. Uses a clean `php_server` directive (Laravel manages its own logging).

Both snippets:
- Import `security.conf` for shared HTTP security headers
- Set `root * {project}/public` as the document root
- Block access to dotfiles and sensitive files (.env, .sql, .log, .bak)
- Enable zstd + gzip compression

### Editable config files

```text
~/Library/Application Support/Nest/config/
├── security.conf      # HTTP security headers (HSTS, XSS, etc.)
├── php.ini            # PHP runtime settings (loaded via PHP_INI_SCAN_DIR)
└── snippets/
    ├── php-app        # Caddy snippet for PHP sites
    └── laravel-app    # Caddy snippet for Laravel sites
```

These files can be edited via the `Config` tab in the desktop app or directly on disk. Changes take effect after a FrankenPHP reload. `php.ini` changes require a restart.

## State ownership

- `sites.json` is the canonical site registry (includes site type: php or laravel)
- `settings.json` stores global bootstrap and runtime state (including bootstrap completion flags)
- `security.conf`, `snippets/*`, `php.ini` are user-editable server configuration
- generated files (`Caddyfile`, symlinks, wrappers, PID files, logs) are derived operational state

## API endpoints

```text
GET/POST /sites                         # List/create sites
PATCH/DELETE /sites/:id                 # Update/delete site
POST /sites/:id/start|stop             # Site control
GET /settings                           # Current settings and bootstrap state
GET/POST /services/start|stop|reload|status
GET /logs/frankenphp                    # Stream logs
GET /php/versions                       # List versions (with full version detection)
POST /php/versions/install|activate
GET /doctor                             # Health checks
POST /doctor/fix                        # Auto-fix a failing check
POST /bootstrap/test-domain             # DNS + PF setup
POST /bootstrap/trust-local-ca          # Add CA to keychain
GET /config/files                       # All config file contents
GET/PUT /config/files/:name             # Read/write individual config file
```
