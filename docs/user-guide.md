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

1. Open the `PHP Versions` screen.
2. Click `Install` for `PHP 8.5`.
3. Click `Activate`.
4. Go to `Dashboard`.
5. Click `Start`.
6. Go to `Settings`.
7. Click `Install .test Routing`.
8. Approve the macOS administrator prompt.
9. Click `Trust Local HTTPS`.

After that, your Mac is ready for local `.test` sites.

## Add A Website

1. Open `Websites`.
2. Click `Add Site`.
3. Fill in:
   `Name`: any label you want
   `Domain`: for example `my-app.test`
   `Root Path`: your project's public folder
   `PHP Version`: `8.5`
4. Save the site.
5. Click `Start` on that site.

Then open:

```text
https://my-app.test
```

## Normal Daily Use

1. Open `Nest.app`.
2. Click `Start` on the dashboard if services are stopped.
3. Start any sites you want.

You do not need to repeat the routing or HTTPS trust steps unless you reset your Mac’s local config.

## If Something Looks Wrong

Open `Settings` and look at the `Doctor` section.

Common fixes:

- If `.test` does not open, run `Install .test Routing` again.
- If the browser warns about HTTPS, run `Trust Local HTTPS` again.
- If another local dev app is running, fully quit Herd before using Nest.
