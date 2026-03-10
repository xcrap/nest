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
	return state.Paths{
		HomeDir:             homeDir,
		BaseDir:             base,
		BinDir:              filepath.Join(base, "bin"),
		VersionsDir:         filepath.Join(base, "versions"),
		PHPVersionsDir:      filepath.Join(base, "versions", "php"),
		ConfigDir:           filepath.Join(base, "config"),
		LogsDir:             filepath.Join(base, "logs"),
		RunDir:              filepath.Join(base, "run"),
		DataDir:             filepath.Join(base, "data"),
		SocketPath:          filepath.Join(base, "run", "nest.sock"),
		SitesPath:           filepath.Join(base, "config", "sites.json"),
		SettingsPath:        filepath.Join(base, "config", "settings.json"),
		CaddyfilePath:       filepath.Join(base, "config", "Caddyfile"),
		FrankenPHPLogPath:   filepath.Join(base, "logs", "frankenphp.log"),
		FrankenPHPPIDPath:   filepath.Join(base, "run", "frankenphp.pid"),
		ComposerWrapperPath: filepath.Join(base, "bin", "composer"),
		ComposerPharPath:    filepath.Join(base, "data", "composer.phar"),
	}
}
