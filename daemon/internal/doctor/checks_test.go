package doctor

import (
	"net"
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
		WithLookPath(func(string) (string, error) { return "", os.ErrNotExist })

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

func TestDoctorDetectsMissingComposer(t *testing.T) {
	paths := tempPaths(t)
	store := config.NewStore(paths)
	if err := store.Ensure(); err != nil {
		t.Fatalf("ensure store: %v", err)
	}

	checks, err := NewService(paths, store).Run()
	if err != nil {
		t.Fatalf("run doctor: %v", err)
	}

	var found bool
	for _, check := range checks {
		if check.ID == "composer-runtime" {
			found = true
			if check.Status != "warn" {
				t.Fatalf("expected composer-runtime warn, got %+v", check)
			}
		}
	}
	if !found {
		t.Fatal("expected composer-runtime check")
	}
}

func TestLaunchAgentHealthy(t *testing.T) {
	if !launchAgentHealthy("type = LaunchAgent\nstate = running\n") {
		t.Fatal("expected launch agent output to be healthy")
	}
	if launchAgentHealthy("type = LaunchAgent\nstate = exited\n") {
		t.Fatal("expected non-running launch agent output to be unhealthy")
	}
}

func TestContainsLoopbackAddress(t *testing.T) {
	if !containsLoopbackAddress([]net.IPAddr{{IP: net.ParseIP("127.0.0.1")}}) {
		t.Fatal("expected loopback address to be accepted")
	}
	if containsLoopbackAddress([]net.IPAddr{{IP: net.ParseIP("192.168.1.20")}}) {
		t.Fatal("expected non-loopback address to be rejected")
	}
}

func TestValidLocalHTTPRoute(t *testing.T) {
	if !validLocalHTTPRoute(308, "https://localhost/") {
		t.Fatal("expected localhost https redirect to be valid")
	}
	if !validLocalHTTPRoute(204, "") {
		t.Fatal("expected direct 204 response to be valid")
	}
	if validLocalHTTPRoute(200, "") {
		t.Fatal("expected arbitrary 200 response to be invalid")
	}
	if validLocalHTTPRoute(308, "https://example.com/") {
		t.Fatal("expected non-local redirect to be invalid")
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
