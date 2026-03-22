# Nest

Nest is a native macOS SwiftUI app for managing local PHP development sites with FrankenPHP and MariaDB.

## What It Does

- Manage website records with `.test` domains
- Start/stop FrankenPHP and MariaDB via Homebrew services
- Generate and reload FrankenPHP/Caddy config automatically
- Edit Caddyfile, security.conf, php.ini, and MariaDB config from the app
- View FrankenPHP and MariaDB logs
- HTTPS with `.test` domains via Caddy's local CA

## Prerequisites

Install the runtimes and DNS resolver via Homebrew:

```bash
brew install dunglas/frankenphp/frankenphp
brew install mariadb
brew install dnsmasq
```

Configure dnsmasq for `.test` domains:

```bash
printf 'port=5354\naddress=/.test/127.0.0.1\nlisten-address=127.0.0.1\n' > /opt/homebrew/etc/dnsmasq.conf
brew services start dnsmasq
```

Set up the macOS DNS resolver (requires sudo):

```bash
sudo mkdir -p /etc/resolver
sudo bash -c 'printf "nameserver 127.0.0.1\nport 5354\n" > /etc/resolver/test'
```

Set up PF port redirect (so `.test` domains work on ports 80/443):

```bash
sudo bash -c 'printf "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\nrdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\n" > /etc/pf.anchors/dev.nest.app'
```

Add these lines to `/etc/pf.conf` (before any existing anchor lines):

```
rdr-anchor "dev.nest.app"
load anchor "dev.nest.app" from "/etc/pf.anchors/dev.nest.app"
```

Then reload: `sudo pfctl -f /etc/pf.conf`

Trust the local CA certificate (after starting FrankenPHP once):

```bash
brew services start frankenphp
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Library/Application\ Support/Caddy/pki/authorities/local/root.crt
```

The app's **Environment** screen verifies all prerequisites with copy-pasteable fix commands.

## Getting Started

1. Complete the prerequisites above.
2. Open `Nest.app` (or `make run` for development).
3. Go to **Runtime Paths** and click **Auto-Detect** (or configure paths manually), then **Save**.
4. Add sites in the **Sites** screen.
5. Start FrankenPHP and MariaDB from the sidebar controls.
6. Open `https://your-site.test`.

## App Data

Nest stores only its own config under `~/Library/Application Support/Nest/config/`:

- `sites.json` — site definitions
- `settings.json` — runtime paths and app settings

All service config files live in their Homebrew default locations:

- `/opt/homebrew/etc/Caddyfile` — FrankenPHP/Caddy config
- `/opt/homebrew/etc/security.conf` — security headers
- `/opt/homebrew/etc/snippets/` — Caddy snippets
- `/opt/homebrew/etc/php.ini` — PHP configuration
- `/opt/homebrew/etc/my.cnf` — MariaDB configuration
- `/opt/homebrew/etc/dnsmasq.conf` — DNS resolver config

FrankenPHP, MariaDB, and dnsmasq all run via `brew services`.

## Repository Layout

- `Sources/NestLib/`: library target (models, services, views)
- `Sources/Nest/`: app entry point (`@main`)
- `Tests/NestTests/`: test runner
- `scripts/`: Info.plist template, entitlements
- `.github/workflows/`: release CI

## Development

```bash
make build      # Build
make run        # Run in development
make test       # Run tests
make package    # Package into Nest.app
```

## Versioning

```bash
make bump VERSION_NEW=x.y.z
git push origin main
git push origin vx.y.z    # triggers GitHub release
```

## Notes

- All runtimes are installed and managed via Homebrew — Nest does not install anything.
- `.test` domain routing requires dnsmasq + resolver + PF rules (see Prerequisites).
- HTTPS requires trusting Caddy's local CA certificate once.
