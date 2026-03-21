# Nest

Nest is a native macOS SwiftUI app for managing local PHP development sites with FrankenPHP and MariaDB.

## What It Does

- Manage website records with `.test` domains
- Configure paths to your Homebrew-installed FrankenPHP and MariaDB
- Generate and reload FrankenPHP/Caddy config automatically
- Start/stop FrankenPHP and MariaDB from the app
- HTTPS with `.test` domains via Caddy's local CA
- Import sites from the legacy Electron+Go version of Nest

## Prerequisites

Nest does not install runtimes. Install them manually:

```bash
brew install frankenphp
brew install mariadb
```

For `.test` domain routing and HTTPS, set up these system prerequisites manually:

1. **DNS resolver**: Create `/etc/resolver/test` pointing to `127.0.0.1`
2. **Port redirect** (optional): PF anchor to redirect ports 80/443 to 8080/8443
3. **Local CA trust**: Trust Caddy's local CA certificate in your system keychain

The app's Environment screen shows the status of each prerequisite with copy-pasteable fix commands.

## Getting Started

1. Open `Nest.app` (or `make run` for development).
2. Go to **Runtime Paths** and configure your FrankenPHP and MariaDB binary paths (or click **Detect Defaults** for Homebrew paths).
3. Add sites in the **Sites** screen.
4. Start/stop sites and services from the UI.
5. Open `https://your-site.test`.

## Managed State

Nest stores config and data under `~/Library/Application Support/Nest`:

- `config/`: `sites.json`, `settings.json`, `Caddyfile`, `security.conf`, `snippets/`
- `data/`: persistent data (MariaDB data directory)
- `logs/`: `frankenphp.log`, `mariadb.log`
- `run/`: PID files

MariaDB defaults:

- host: `127.0.0.1`
- port: `3306`
- user: `root`
- password: none

## Repository Layout

- `Sources/NestLib/`: library target (models, services, views)
- `Sources/Nest/`: app entry point (`@main`)
- `Tests/NestTests/`: test runner
- `scripts/`: Info.plist template, entitlements
- `.github/workflows/`: release CI

## Development

Build:

```bash
make build
```

Run (development):

```bash
make run
```

Test:

```bash
make test
```

Package into `Nest.app`:

```bash
make package
```

## Migration from Legacy App

If you used the previous Electron+Go version of Nest:

1. Export your sites from the old app (Sites > Export).
2. Export your MariaDB databases with `mysqldump`.
3. Open the new Nest app and go to **Migration**.
4. Import your `nest-sites.json` file.
5. Restore your database dumps manually with the MariaDB client.

## Versioning

The app version lives in `version.txt`. Bump it with:

```bash
make bump VERSION_NEW=x.y.z
```

Push a `v*` tag to trigger a GitHub release:

```bash
git tag v0.6.0
git push origin main
git push origin v0.6.0
```

## Notes

- Nest manages FrankenPHP and MariaDB processes but does not install them.
- The `.test` domain routing and HTTPS trust are documented manual prerequisites.
- This repository keeps all project documentation in this `README.md`.
