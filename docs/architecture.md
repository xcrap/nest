# Architecture

## Components

### Go daemon and CLI

The daemon owns local state, exposes a Unix socket HTTP API, runs the `.test` DNS responder, supervises FrankenPHP, and generates Caddy configuration. `nestctl` is a thin client over the same socket API with a few direct filesystem helpers for bootstrap-friendly commands.

### Electron desktop app

The GUI is a control plane only. It talks to the daemon through Electron IPC in the main process, which bridges renderer actions to the Unix socket API.

### Privileged helper

The helper is intentionally small and macOS-only. It performs one-time bootstrap tasks:

- create `/etc/resolver/test` pointing to `127.0.0.1` port `5354`
- install PF redirection from `80 -> 8080` and `443 -> 8443`
- reserve a place for CA trust/bootstrap flows

## Traffic model

- `*.test` DNS resolution goes to the daemon's local DNS server on `127.0.0.1:5354`
- PF redirects browser traffic on `80/443` to FrankenPHP on `8080/8443`
- FrankenPHP/Caddy terminates TLS and serves PHP/static files for running sites

## State ownership

- `sites.json` is the canonical site registry
- `settings.json` stores global bootstrap and runtime state
- generated files (`Caddyfile`, symlinks, wrappers, PID files, logs) are derived operational state
