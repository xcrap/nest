package composer

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/xcrap/nest/daemon/internal/state"
)

func TestDetectMissingComposer(t *testing.T) {
	paths := tempPaths(t)

	runtime, err := Detect(context.Background(), paths)
	if err != nil {
		t.Fatalf("detect composer: %v", err)
	}
	if runtime.Installed {
		t.Fatalf("expected composer to be missing, got %+v", runtime)
	}
	if runtime.Status != "not_installed" {
		t.Fatalf("expected not_installed status, got %+v", runtime)
	}
}

func TestInstallAndRollbackComposer(t *testing.T) {
	paths := tempPaths(t)
	if err := paths.Ensure(); err != nil {
		t.Fatalf("ensure paths: %v", err)
	}
	if err := os.WriteFile(paths.ActivePHPPath(), []byte("php"), 0o755); err != nil {
		t.Fatalf("write php stub: %v", err)
	}
	if err := os.WriteFile(paths.ComposerPharPath, []byte("old"), 0o644); err != nil {
		t.Fatalf("write existing composer: %v", err)
	}

	originalFetchRelease := fetchRelease
	originalResolveVersion := resolveVersion
	t.Cleanup(func() {
		fetchRelease = originalFetchRelease
		resolveVersion = originalResolveVersion
	})

	fetchRelease = func(context.Context, state.Paths) (Release, string, error) {
		tempPath := filepath.Join(paths.DataDir, "composer-download.phar")
		if err := os.WriteFile(tempPath, []byte("new"), 0o644); err != nil {
			return Release{}, "", err
		}
		return Release{
			Version:     "2.9.5",
			SourceURL:   "https://getcomposer.org/download/latest-stable/composer.phar",
			ChecksumURL: "https://getcomposer.org/download/latest-stable/composer.phar.sha256sum",
			SHA256:      "abc123",
		}, tempPath, nil
	}
	resolveVersion = func(_ context.Context, _ string, pharPath string) (string, error) {
		if strings.HasSuffix(pharPath, "composer.previous.phar") {
			return "2.9.4", nil
		}
		return "2.9.5", nil
	}

	runtime, err := Install(context.Background(), paths)
	if err != nil {
		t.Fatalf("install composer: %v", err)
	}
	if !runtime.Installed {
		t.Fatalf("expected composer to be installed, got %+v", runtime)
	}
	if !runtime.BackupAvailable {
		t.Fatalf("expected rollback backup to exist after install, got %+v", runtime)
	}

	current, err := os.ReadFile(paths.ComposerPharPath)
	if err != nil {
		t.Fatalf("read composer phar: %v", err)
	}
	if string(current) != "new" {
		t.Fatalf("expected new composer phar contents, got %q", string(current))
	}

	backup, err := os.ReadFile(paths.ComposerBackupPath)
	if err != nil {
		t.Fatalf("read composer backup: %v", err)
	}
	if string(backup) != "old" {
		t.Fatalf("expected composer backup to keep previous phar, got %q", string(backup))
	}

	runtime, err = Rollback(context.Background(), paths)
	if err != nil {
		t.Fatalf("rollback composer: %v", err)
	}

	current, err = os.ReadFile(paths.ComposerPharPath)
	if err != nil {
		t.Fatalf("read rolled-back composer phar: %v", err)
	}
	if string(current) != "old" {
		t.Fatalf("expected rollback to restore previous composer phar, got %q", string(current))
	}

	backup, err = os.ReadFile(paths.ComposerBackupPath)
	if err != nil {
		t.Fatalf("read swapped composer backup: %v", err)
	}
	if string(backup) != "new" {
		t.Fatalf("expected rollback to keep replaced phar as backup, got %q", string(backup))
	}
}

func tempPaths(t *testing.T) state.Paths {
	t.Helper()

	homeDir := t.TempDir()
	base := filepath.Join(homeDir, "Library", "Application Support", "Nest")
	configDir := filepath.Join(base, "config")
	return state.Paths{
		HomeDir:             homeDir,
		BaseDir:             base,
		BinDir:              filepath.Join(base, "bin"),
		VersionsDir:         filepath.Join(base, "versions"),
		PHPVersionsDir:      filepath.Join(base, "versions", "php"),
		MariaDBVersionsDir:  filepath.Join(base, "versions", "mariadb"),
		ConfigDir:           configDir,
		SnippetsDir:         filepath.Join(configDir, "snippets"),
		LogsDir:             filepath.Join(base, "logs"),
		RunDir:              filepath.Join(base, "run"),
		DataDir:             filepath.Join(base, "data"),
		SocketPath:          filepath.Join(base, "run", "nest.sock"),
		SitesPath:           filepath.Join(configDir, "sites.json"),
		SettingsPath:        filepath.Join(configDir, "settings.json"),
		CaddyfilePath:       filepath.Join(configDir, "Caddyfile"),
		SecurityConfPath:    filepath.Join(configDir, "security.conf"),
		PHPIniPath:          filepath.Join(configDir, "php.ini"),
		FrankenPHPLogPath:   filepath.Join(base, "logs", "frankenphp.log"),
		FrankenPHPPIDPath:   filepath.Join(base, "run", "frankenphp.pid"),
		MariaDBConfigPath:   filepath.Join(configDir, "mariadb.cnf"),
		MariaDBLogPath:      filepath.Join(base, "logs", "mariadb.log"),
		MariaDBPIDPath:      filepath.Join(base, "run", "mariadb.pid"),
		MariaDBSocketPath:   filepath.Join(base, "run", "mariadb.sock"),
		MariaDBDataDir:      filepath.Join(base, "data", "mariadb"),
		ComposerWrapperPath: filepath.Join(base, "bin", "composer"),
		ComposerPharPath:    filepath.Join(base, "data", "composer.phar"),
		ComposerBackupPath:  filepath.Join(base, "data", "composer.previous.phar"),
	}
}
