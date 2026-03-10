# Nest

Nest is a macOS-first local PHP development app that replaces Herd with FrankenPHP, local `.test` domains, HTTPS, and a desktop UI.

If you are using Nest as an app, start here:

- [User Guide](docs/user-guide.md)

If you are coding on Nest itself, start here:

- [Developer Setup](docs/setup-and-run.md)
- [Release Process](docs/releasing.md)

## User View

As a user, you should ignore the repo folders. The thing you run is `Nest.app` in the project root.

The end-user flow is:

1. Open `Nest.app` in the project root.
2. Install PHP from the `PHP Versions` screen.
3. Start services from the dashboard.
4. Open `Settings` and run:
   `Install .test Routing`
   `Trust Local HTTPS`
5. Add a site in `Websites`.
6. Open `https://your-site.test`.

## Developer View

Internal folders:

- `daemon/`: Go daemon and CLI
- `desktop/`: Electron + React UI
- `helper/`: privileged macOS helper
- `docs/`: user and developer documentation

## Notes

- MariaDB stays external for v1.
- Nest should not run at the same time as Herd.
- The packaged app is currently unsigned.
