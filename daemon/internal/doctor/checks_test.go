package doctor

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/state"
)

func TestDoctorDetectsMissingShellPath(t *testing.T) {
	paths := tempPaths(t)
	store := config.NewStore(paths)
	if err := store.Ensure(); err != nil {
		t.Fatalf("ensure store: %v", err)
	}

	service := NewService(paths, store).
		WithLookPath(func(string) (string, error) { return "", os.ErrNotExist }).
		WithProcessRunning(func(string) bool { return false })

	checks, err := service.Run()
	if err != nil {
		t.Fatalf("run doctor: %v", err)
	}

	var found bool
	for _, check := range checks {
		if check.ID == "shell-path" {
			found = true
			if check.Status != "warn" {
				t.Fatalf("expected shell-path warn, got %+v", check)
			}
		}
	}
	if !found {
		t.Fatal("expected shell-path check")
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
	}
}
