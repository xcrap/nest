package runtime

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/xcrap/nest/daemon/internal/config"
	fpmeta "github.com/xcrap/nest/daemon/internal/frankenphp"
	"github.com/xcrap/nest/daemon/internal/state"
)

type Manager struct {
	paths state.Paths
	store *config.Store
}

func NewManager(paths state.Paths, store *config.Store) *Manager {
	return &Manager{
		paths: paths,
		store: store,
	}
}

func (m *Manager) SupportedVersions() ([]config.PhpVersion, error) {
	settings, err := m.store.LoadSettings()
	if err != nil {
		return nil, err
	}

	release := fpmeta.CurrentRelease()
	version := release.EmbeddedPHPVersion
	binaryPath := m.binaryPathForVersion(version)
	_, statErr := os.Stat(binaryPath)
	installed := statErr == nil

	fullVersion := ""
	if installed {
		fullVersion = m.detectFullPHPVersion()
	}

	return []config.PhpVersion{
		{
			Version:           version,
			FullVersion:       fullVersion,
			FrankenPHPVersion: release.Version,
			Installed:         installed,
			Active:            settings.ActivePHPVersion == version,
			Path:              binaryPath,
		},
	}, nil
}

func (m *Manager) Install(ctx context.Context, version string) error {
	if version != fpmeta.CurrentRelease().EmbeddedPHPVersion {
		return fmt.Errorf("php %s is not supported by the pinned FrankenPHP runtime; install %s", version, fpmeta.CurrentRelease().EmbeddedPHPVersion)
	}

	if err := fpmeta.InstallBinary(ctx, m.paths.FrankenPHPPath()); err != nil {
		return err
	}

	versionDir := filepath.Join(m.paths.PHPVersionsDir, version)
	if err := os.RemoveAll(versionDir); err != nil {
		return err
	}
	binDir := filepath.Join(versionDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return err
	}

	wrapperPath := filepath.Join(binDir, "php")
	wrapper := "#!/usr/bin/env bash\n" +
		"set -euo pipefail\n" +
		"FRANKENPHP_BIN=\"" + m.paths.FrankenPHPPath() + "\"\n" +
		"exec \"$FRANKENPHP_BIN\" php-cli \"$@\"\n"
	if err := os.WriteFile(wrapperPath, []byte(wrapper), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(wrapperPath); err != nil {
		return fmt.Errorf("php binary missing after install for %s", version)
	}

	return nil
}

func (m *Manager) Activate(version string) error {
	binaryPath := m.binaryPathForVersion(version)
	if _, err := os.Stat(binaryPath); err != nil {
		return fmt.Errorf("php %s is not installed", version)
	}

	if err := os.RemoveAll(m.paths.ActivePHPPath()); err != nil {
		return err
	}
	if err := os.Symlink(binaryPath, m.paths.ActivePHPPath()); err != nil {
		return err
	}

	settings, err := m.store.LoadSettings()
	if err != nil {
		return err
	}
	settings.ActivePHPVersion = version
	return m.store.SaveSettings(settings)
}

func (m *Manager) binaryPathForVersion(version string) string {
	return filepath.Join(m.paths.PHPVersionsDir, version, "bin", "php")
}

func (m *Manager) detectFullPHPVersion() string {
	cmd := exec.Command(m.paths.FrankenPHPPath(), "php-cli", "-v")
	output, err := cmd.Output()
	if err != nil {
		return ""
	}
	line := strings.SplitN(string(output), "\n", 2)[0]
	// "PHP 8.5.1 (cli) ..." -> "8.5.1"
	parts := strings.Fields(line)
	if len(parts) >= 2 && parts[0] == "PHP" {
		return parts[1]
	}
	return ""
}
