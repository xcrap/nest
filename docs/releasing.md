# Releasing Nest

## Local release build

To build macOS release artifacts locally:

```bash
make release
```

Artifacts are written to:

- `desktop/release/*.dmg`
- `desktop/release/*.zip`

## GitHub Releases

This repo includes `.github/workflows/release.yml`.

When you push a tag like `v0.2.0`, GitHub Actions will:

1. install Node and Go
2. run `go test ./...`
3. build the desktop app as `dmg` and `zip`
4. attach those files to the GitHub Release for that tag

## In-app release checks

The desktop app checks GitHub Releases for `xcrap/nest` by default.

Override the release source with:

```bash
export NEST_GITHUB_REPOSITORY="owner/repo"
```

The app currently checks for the latest release and opens the download URL for the matching DMG or ZIP asset.
