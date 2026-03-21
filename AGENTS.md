# AGENTS.md

This file gives AI coding agents the stable context needed to work in this repository without relying on a separate docs tree.

## Purpose

Nest is a native macOS SwiftUI app for managing local PHP development sites.

Core responsibilities:

- manage website records (sites with `.test` domains)
- manage user-provided FrankenPHP and MariaDB executable paths
- generate and reload FrankenPHP/Caddy config for those sites
- start/stop/reload FrankenPHP and MariaDB from the app
- verify system prerequisites for `.test` routing and HTTPS
- import legacy site data from the previous Electron+Go app

## High-Level Architecture

Single Swift Package with two targets:

- `NestLib`: library target containing models, services, and views
  - `Models/`: `Site`, `RuntimePaths`, `AppSettings`, `MigrationManifest`
  - `Services/`: `SiteStore`, `ProcessController`, `ConfigRenderer`, `MigrationService`, `PrerequisiteChecker`
  - `Views/`: `ContentView`, `SitesView`, `SiteFormSheet`, `RuntimePathsView`, `ConfigPreviewView`, `MigrationView`, `EnvironmentChecksView`
- `Nest`: executable target with the SwiftUI `@main` app entry point
- `NestTests`: test runner executable

Other directories:

- `scripts/`: Info.plist template, entitlements plist
- `.github/workflows/`: release CI pipeline

## Runtime State

Nest stores managed state under:

- `~/Library/Application Support/Nest`

Common locations:

- `config/`: `sites.json`, `settings.json`, `Caddyfile`, `security.conf`, `snippets/`
- `data/`: persistent data (e.g. MariaDB data directory)
- `logs/`: `frankenphp.log`, `mariadb.log`
- `run/`: PID files, sockets

Nest does NOT install runtimes. FrankenPHP and MariaDB are installed manually via Homebrew.

## Working Style

- Start by reading the relevant Swift source files before editing.
- Keep user-facing behavior aligned with the packaged `Nest.app`.
- Prefer changing source files, not packaged outputs.
- Keep documentation centralized in `README.md`.

## Versioning

The app version lives in `version.txt`. Use the bump target:

```bash
make bump VERSION_NEW=x.y.z
```

Git tags use the `vX.Y.Z` format. Pushing a `v*` tag triggers the GitHub release workflow.

## Common Commands

Build:

```bash
make build
```

Test:

```bash
make test
```

Run (development):

```bash
make run
```

Package (create Nest.app):

```bash
make package
```

## Change Boundaries

- When changing models or services in `NestLib`, ensure both the app and tests still build.
- When changing config generation, verify the rendered Caddyfile matches expected format.
- When changing UI, run the app to verify (`make run`).
- After significant changes, rebuild the `.app` bundle (`make package`).
