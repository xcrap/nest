# Nest

Nest is a macOS local PHP development app with a desktop UI, a Nest-managed FrankenPHP runtime, a Nest-managed Composer runtime, a Homebrew-managed MariaDB runtime, local `.test` domains, HTTPS bootstrap, and site management.

## What You Run

If you are using Nest as a product, open `Nest.app` in the project root.

Typical flow:

1. Open `Nest.app`.
2. Install PHP from the `PHP` screen.
3. Install Composer from the `PHP` screen if your project needs it.
4. Install MariaDB from the `MariaDB` screen if your project needs a database. Nest installs and pins `mariadb@10.11` with Homebrew.
5. Start services from the header controls.
6. In `Settings`, run `Install .test Routing` and `Trust Local HTTPS`.
7. Add sites in `Sites`.
8. Open `https://your-site.test`.

Nest runs `nestd` as a per-user background service. The desktop app is a client and can be opened or closed independently.

## Managed Runtime Layout

Nest manages its own runtime state under:

- `~/Library/Application Support/Nest`

Important paths:

- `versions/php`: installed PHP runtimes
- `data/composer.phar`: managed Composer runtime
- `data/mariadb`: MariaDB data directory
- `config/mariadb.cnf`: MariaDB config file
- `run/mariadb.sock`: MariaDB socket
- `logs/`: service logs
- `bin/`: active runtime symlinks and wrappers

MariaDB defaults:

- formula: `mariadb@10.11` via Homebrew
- host: `127.0.0.1`
- port: `3306`
- user: `root`
- password: none

Nest uses Homebrew to install and pin MariaDB, but Nest still manages the process, config, data dir, socket, and shell wrappers itself. Nest does not use `brew services`.

Composer defaults:

- source: `https://getcomposer.org/download/latest-stable/composer.phar`
- checksum: `https://getcomposer.org/download/latest-stable/composer.phar.sha256sum`
- wrapper: `~/Library/Application Support/Nest/bin/composer`
- rollback backup: `~/Library/Application Support/Nest/data/composer.previous.phar`

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

Run the desktop app in development:

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
nestcli site add --name NAME --domain DOMAIN --root PATH [--document-root public|.|web]
nestcli site remove ID
nestcli site start ID
nestcli site stop ID

nestcli php list
nestcli php install VERSION
nestcli php activate VERSION

nestcli composer status
nestcli composer install
nestcli composer update
nestcli composer rollback
nestcli composer check-updates

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
sudo nestcli bootstrap test-domain
sudo nestcli bootstrap unbootstrap-test-domain
sudo nestcli bootstrap trust-local-ca
sudo nestcli bootstrap untrust-local-ca
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

- Nest manages one active PHP runtime through FrankenPHP.
- Nest manages Composer as an official `composer.phar` download with checksum verification and rollback backup.
- Nest installs MariaDB through Homebrew and pins the supported formula automatically.
- The root `Nest.app` in this repo is the main packaged output to test.
- This repository keeps project documentation in this `README.md`.
