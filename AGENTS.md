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

Single Swift Package with three executable targets plus a library:

- `NestLib`: library target containing models, services, and views
  - `Models/`: `Site`, `RuntimePaths`, `AppSettings`, `MigrationManifest`
  - `Services/`: `SiteStore`, `ProcessController`, `ConfigRenderer`, `MigrationService`, `PrerequisiteChecker`, `PFHelperManager`
  - `Views/`: `ContentView`, `SitesView`, `SiteFormSheet`, `RuntimePathsView`, `ConfigPreviewView`, `MigrationView`, `EnvironmentChecksView`
- `Nest`: executable target with the SwiftUI `@main` app entry point
- `NestPFHelper`: privileged root daemon embedded in the prod app bundle. Writes `/etc/pf.anchors/app.nest`, repairs `/etc/pf.conf` if macOS resets it, runs `pfctl -Ef` on boot. Registered via `SMAppService.daemon`; dev builds (ad-hoc signed) can't bless it, so they keep the legacy osascript fallback in `ProcessController.reloadPFRules`.
- `NestTests`: test runner executable

Other directories:

- `scripts/`: Info.plist template, entitlements plist, `app.nest.pfhelper.plist` (launchd plist for the helper)
- `.github/workflows/`: release CI pipeline

## Runtime State

Nest stores only its own data under a bundle-specific app support directory:

- development app: `~/Library/Application Support/dev.nest.app/config/`
- packaged app: `~/Library/Application Support/app.nest/config/`

- `sites.json`, `settings.json`

All service config files live at Homebrew defaults (`/opt/homebrew/etc/`):

- `Caddyfile`, `security.conf`, `snippets/` — FrankenPHP/Caddy
- `php.ini` — PHP
- `my.cnf` — MariaDB
- `dnsmasq.conf` — DNS for `.test` domains

FrankenPHP, MariaDB, and dnsmasq are all installed and managed via Homebrew (`brew services`). Nest does NOT install runtimes.

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
make dev
```

Package (create Nest.app):

```bash
make package
```

## Change Boundaries

- When changing models or services in `NestLib`, ensure both the app and tests still build.
- When changing config generation, verify the rendered Caddyfile matches expected format.
- When changing UI, run the app to verify (`make dev`).
- After significant changes, rebuild the `.app` bundle (`make package`).
