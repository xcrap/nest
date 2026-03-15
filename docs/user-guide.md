# User Guide

This guide is for someone who wants to use Nest, not code on it.

Ignore `daemon/`, `desktop/`, `helper/`, and the repo layout. The app you run is:

- `Nest.app`

## Install

1. Move `Nest.app` into `/Applications`.
2. Open `Nest.app`.
3. If macOS warns because the app is unsigned, right-click it and choose `Open`.

## First Run

Do these once on your Mac:

1. Open `Dashboard`.
2. If `php-symlink` or `shell-path` checks are failing, click the `Fix` button next to each one.
3. Click `Start` in the header.
4. Go to `Settings`.
5. Click `Run bootstrap` (approves macOS admin prompt to install `.test` DNS routing).
6. Click `Trust CA` (approves macOS admin prompt to trust the local HTTPS certificate).

Once done, both actions show green badges (`Configured` and `Trusted`) so you know they're complete.

## Add A Website

1. Open `Sites`.
2. Click `Add site`.
3. Fill in:
   - `Name`: any label you want
   - `Type`: `PHP` for custom PHP sites or `Laravel` for Laravel projects
   - `Domain`: for example `my-app.test`
   - `Project root`: your project folder (e.g. `/Users/you/Sites/my-app`). The server automatically serves from the `public` subfolder.
   - `PHP Version`: `8.5`
4. Click `Create`.
5. Click the power button to start that site.

Then open:

```text
https://my-app.test
```

## Site Types

- **PHP**: Uses the `php-app` Caddy snippet. Includes PHP error logging directives.
- **Laravel**: Uses the `laravel-app` Caddy snippet. Laravel handles its own logging.

Both types set the document root to `{project}/public` and apply the shared security headers.

## Configuration

Open the `Config` tab to edit server configuration files:

- **Security**: HTTP security headers applied to every site (HSTS, XSS protection, etc.)
- **PHP App**: Caddy snippet template for PHP sites
- **Laravel App**: Caddy snippet template for Laravel projects
- **php.ini**: PHP runtime settings (error reporting, socket paths, etc.)

After editing, click `Save & Reload` to apply changes immediately.

## PHP Runtimes

Open the `PHP` tab to see installed runtimes with full version info (e.g. PHP 8.5.1, FrankenPHP v1.12.0).

- **Reinstall**: Re-downloads the FrankenPHP binary to pick up updates.
- **Activate**: Sets a version as the active PHP for new sites.

## CLI Reference

If you prefer the terminal, `nestcli` provides the same functionality:

```bash
# Sites
nestcli site list
nestcli site add --name NAME --domain DOMAIN --root PATH [--type php|laravel] [--php-version VERSION] [--https=true]
nestcli site remove ID
nestcli site start ID
nestcli site stop ID

# PHP
nestcli php list
nestcli php install 8.5
nestcli php activate 8.5

# Services
nestcli services start
nestcli services stop
nestcli services reload
nestcli services status

# Health
nestcli doctor

# Shell integration
nestcli shell integrate --zsh

# Bootstrap (requires sudo from CLI, or use the app)
sudo nestcli bootstrap test-domain
sudo nestcli bootstrap trust-local-ca
```

## Normal Daily Use

1. Open `Nest.app`.
2. Click `Start` in the header if services are stopped.
3. Start any sites you want.

You do not need to repeat the routing or HTTPS trust steps unless you reset your Mac's local config.

## If Something Looks Wrong

Open `Dashboard` and look at the `Doctor checks` section.

- Failing checks (`php-symlink`, `shell-path`, `frankenphp-binary`) have a `Fix` button you can click directly.
- If `.test` does not open, go to `Settings` and re-run bootstrap.
- If the browser warns about HTTPS, go to `Settings` and re-trust the local CA.
- If another local dev app is running, fully quit Herd before using Nest.
