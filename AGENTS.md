# AGENTS.md

This file gives AI coding agents the stable context needed to work in this repository without relying on a separate docs tree.

## Purpose

Nest is a macOS local development app for PHP projects.

Core responsibilities:

- manage local PHP runtimes
- manage a local MariaDB runtime
- manage local `.test` routing and HTTPS bootstrap
- manage site definitions and service state
- package a desktop app as `Nest.app`

## High-Level Architecture

- `daemon/`: Go backend, local API, runtime management, site/service orchestration, `nestcli`
- `desktop/`: Electron + React desktop app
- `helper/`: privileged macOS helper for system-level setup tasks
- `scripts/`: bootstrap and release helpers
- `bin/`: local build outputs
- `Nest.app`: packaged app copied to the repo root by `make package`

## Runtime State

Nest stores managed state under:

- `~/Library/Application Support/Nest`

Common locations:

- `versions/`: installed runtimes
- `data/`: persistent runtime data
- `config/`: generated config files
- `logs/`: service logs
- `run/`: sockets and pid files
- `bin/`: active runtime symlinks and wrappers

Do not assume Homebrew-managed runtimes are present or required.

## Working Style

- Start by reading the relevant Go or React entry points before editing.
- Keep user-facing behavior aligned with the packaged root `Nest.app`.
- Prefer changing source files, not packaged outputs.
- Keep documentation centralized in `README.md`.
- Avoid introducing repo instructions that need constant feature-by-feature maintenance.

## Versioning

The app version lives in `package.json` (root) and `desktop/package.json`. Both must stay in sync. Use the bump target to update them together:

```bash
make bump VERSION=x.y.z
```

- The Makefile reads the root `package.json` version and injects it into the Go daemon via `-ldflags`.
- Electron reads `desktop/package.json` via `app.getVersion()`.
- Git tags use the `vX.Y.Z` format (e.g. `v0.3.5`).

Running `make bump` updates both files, commits, and creates the git tag locally. Pushing a `v*` tag triggers the GitHub release workflow — only push the tag when ready to publish a release. Always push the commit (`git push origin main`) separately from the tag (`git push origin vX.Y.Z`).

## Common Commands

Bootstrap:

```bash
make bootstrap
```

Development:

```bash
make dev
```

Build:

```bash
make build
```

Test:

```bash
make test
```

Package:

```bash
make package
```

Useful direct commands:

```bash
./bin/nestcli doctor
./bin/nestcli services status
./bin/nestcli php list
./bin/nestcli mariadb status
```

## Change Boundaries

- Keep desktop, daemon, and helper changes consistent when a feature crosses layers.
- When changing runtime installation behavior, verify both fresh install and restart behavior.
- When changing UI-visible behavior, rebuild the root `Nest.app` before considering the task complete.
- Prefer stable, general project guidance over feature-specific historical notes in this file.
