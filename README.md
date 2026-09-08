# Nest

Nest is a native macOS SwiftUI app for managing local PHP development sites with FrankenPHP and MariaDB.

## What It Does

- Manage command-based projects, Cloudflare tunnel routes, and DNS records

- Manage website records with `.test` domains
- Start/stop FrankenPHP and MariaDB via Homebrew services
- Generate and reload FrankenPHP/Caddy config automatically
- Edit Caddyfile, security.conf, php.ini, and MariaDB config from the app
- View FrankenPHP and MariaDB logs
- HTTPS with `.test` domains via Caddy's local CA
- Optional `nestctl` CLI for automation (`start`, `stop`, `reload`, `render`, `doctor`, `push-cloudflare`)

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

- **Packaged app (DMG install):** open **Environment** → Port Redirect row → click **Install Helper**, then approve in System Settings → General → Login Items & Extensions. Ports 80/443 will redirect to 8080/8443 automatically on every boot — no terminal required.
- **Developing from source (`make dev`):** the blessed helper needs Developer ID signing, so dev builds fall back to a manual one-time setup:

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
2. Open `Nest.app` (or `make dev` for development).
3. Go to **Settings → Paths** and click **Auto-Detect** (or configure paths manually), then **Save**.
4. Add sites in the **Sites** screen.
5. Start FrankenPHP and MariaDB from the sidebar controls.
6. Open `https://your-site.test`.

## App Data

Nest stores its own config under a bundle-specific app support directory:

- development app: `~/Library/Application Support/dev.nest.app/config/`
- packaged app: `~/Library/Application Support/app.nest/config/`

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
- `Sources/NestPFHelper/`: privileged root daemon for PF port redirects (prod bundle only)
- `Sources/NestCTL/`: `nestctl` command-line helper
- `Tests/NestTests/`: test runner
- `scripts/`: Info.plist template, entitlements, PF helper launchd plist
- `.github/workflows/`: release CI

## Development

```bash
make build      # Build
make dev        # Build and open the dev app
make run        # Alias for make dev
make test       # Run tests
make package    # Package into Nest.app
dist/nestctl help
```

## Versioning

```bash
make bump VERSION_NEW=x.y.z
git push origin main
git push origin vx.y.z    # triggers GitHub release
gh run list --limit 1     # verify release workflow status
```

## Notes

- All runtimes are installed and managed via Homebrew — Nest does not install anything.
- `.test` domain routing requires dnsmasq + resolver + PF rules (see Prerequisites). Packaged builds manage PF via a privileged SMAppService helper; dev builds require a one-time manual pfctl setup.
- HTTPS requires trusting Caddy's local CA certificate once.

## Daily Workflow

- **Sites** supports sorting by name, domain, or folder; pinned sites stay first. Use the All / Pinned / Recent filter, or search names, domains, and paths. Select a row with the keyboard and use **Cmd+O** (browser), **Cmd+Shift+F** (Finder), **Cmd+Shift+T** (Terminal), or **Cmd+E** (edit).
- A site's **Enabled** switch controls its generated Caddy route. It does not claim that PHP, DNS, TLS, or the application itself is healthy. Changes to site records are validated and applied automatically; the status strip reports pending, applying, applied, or failed changes. **Apply** retries a failed operation.
- **Projects** manages commands through per-project launch agents. Existing jobs from either the development or packaged Nest build are recognized when their project ID, directory and port match. Stop targets the matching launch agent, and the next Start uses the current build's namespace. A port used by an unrelated process remains a conflict; Nest does not kill arbitrary processes using that port.
- **Tunnels** stores the desired public-to-local routes. Changes remain pending until **Apply Changes** validates the YAML and restarts the running local connector. **Check** performs a separate public HTTPS request and shows its HTTP result. A running connector does not imply a healthy public route.
- **DNS** manages Cloudflare DNS records separately from tunnel ingress. **Settings → Cloudflare → Push to Cloudflare** applies local configuration and also pushes API ingress. Partial failures identify which step completed.
- **Settings → Environment** contains prerequisites and service diagnostics. **Settings → Paths** contains runtime paths. Service failures also appear directly in the sidebar.

## Configuration Safety

**Settings → Config** displays generated Caddyfile and cloudflared YAML as read-only. Use site/route records to change generated routing. Add custom Caddy configuration in **Overrides** (`overrides/custom.caddy`), or edit `security.conf` and `php-app`; these files are preserved during regeneration.

Editor drafts survive tab and section changes. Quit asks before discarding unsaved drafts. The editor detects external file changes, reports write failures, and offers **Recovery → Restore Previous Version** or **Discard & Reload**. Caddy support files are validated in an isolated staging directory before saving and reloading. PHP and MariaDB configuration saves require a service restart to take effect.

Before replacing a file, Nest saves its previous contents in a `.nest-backups` directory one level above the file's parent. Backups are kept outside Caddy import globs. A rejected apply restores the previous file; failed tunnel restart recovery also attempts to restart the previous configuration. A failed remote API push reports partial success instead of pretending the whole operation completed.

Cloudflare API tokens are stored in the macOS Keychain under the app's bundle-specific service and excluded from JSON settings and exports. Existing plaintext tokens migrate only after Keychain storage succeeds. Importing a token-free export preserves the existing token. Historical backups created by older Nest versions are not automatically removed and may still contain old credentials.

## Verification

`make test` includes configuration rollback, rejected reload/validation, preserved overrides, editor draft/write/conflict handling, process ownership, subprocess deadlines/cancellation/output, and credential migration/export tests. The build-and-test workflow also runs on main pushes and pull requests, with a package signature check.

For isolated debug UI verification, use `make dev DEV_ARGS="--review-data /absolute/path/to/fixture-config"`. This loads fixture JSON with an in-memory credential store and disables automatic service monitoring/network repair and update checks. It is available only in debug builds; fixture paths should point exclusively to disposable config files. Explicit service buttons still perform their normal actions.
