# Nest

Nest is a macOS local PHP development app with a desktop UI, Nest-managed PHP and MariaDB runtimes, local `.test` domains, HTTPS bootstrap, and site management.

## What You Run

If you are using Nest as a product, open `Nest.app` in the project root.

Typical flow:

1. Open `Nest.app`.
2. Install PHP from the `PHP` screen.
3. Install MariaDB from the `MariaDB` screen if your project needs a database.
4. Start services from the header controls.
5. In `Settings`, run `Install .test Routing` and `Trust Local HTTPS`.
6. Add sites in `Sites`.
7. Open `https://your-site.test`.

## Managed Runtime Layout

Nest manages its own runtime state under:

- `~/Library/Application Support/Nest`

Important paths:

- `versions/php`: installed PHP runtimes
- `versions/mariadb`: installed MariaDB runtimes
- `data/mariadb`: MariaDB data directory
- `config/mariadb.cnf`: MariaDB config file
- `run/mariadb.sock`: MariaDB socket
- `logs/`: service logs
- `bin/`: active runtime symlinks and wrappers

MariaDB defaults:

- host: `127.0.0.1`
- port: `3306`
- user: `root`
- password: none

## Repository Layout

- `daemon/`: Go daemon, API, services, and `nestcli`
- `desktop/`: Electron + React desktop app
- `helper/`: privileged macOS helper
- `scripts/`: bootstrap and release support scripts
- `bin/`: local build outputs
- `Nest.app`: packaged desktop app copied to the repo root by `make package`

## Local Development

Bootstrap:

```bash
make bootstrap
```

Run the daemon and desktop app in development:

```bash
make dev
```

Build the binaries and frontend:

```bash
make build
```

Run tests:

```bash
make test
```

Build a fresh root app bundle:

```bash
make package
```

## CLI

Main commands:

```bash
nestcli site list
nestcli site add --name NAME --domain DOMAIN --root PATH [--document-root public|.|web] [--php-version VERSION] [--https=true]
nestcli site remove ID
nestcli site start ID
nestcli site stop ID

nestcli php list
nestcli php install VERSION
nestcli php activate VERSION

nestcli mariadb status
nestcli mariadb install
nestcli mariadb start
nestcli mariadb stop
nestcli mariadb check-updates

nestcli services start
nestcli services stop
nestcli services reload
nestcli services status

nestcli doctor
nestcli shell integrate --zsh
nestcli bootstrap test-domain
sudo nestcli bootstrap trust-local-ca
```

## Versioning

Bump the version, commit, and create a `vx.y.z` git tag locally:

```bash
make bump VERSION=x.y.z
```

Push the commit:

```bash
git push origin main
```

Optionally, push the tag to trigger a GitHub release:

```bash
git push origin vx.y.z
```

Pushing a `v*` tag triggers the GitHub release workflow. Only do this when you want to publish a release.

## Packaging

`make package` builds:

- `bin/nestd`
- `bin/nestcli`
- `bin/nesthelper`
- `desktop/release/mac-arm64/Nest.app`
- root `./Nest.app`

## Notes

- Nest runtime binaries are app-managed and do not require Homebrew runtime packages.
- The root `Nest.app` in this repo is the main packaged output to test.
- This repository keeps project documentation in this `README.md`.
