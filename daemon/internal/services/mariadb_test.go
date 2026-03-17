package services

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/xcrap/nest/daemon/internal/state"
)

func TestShouldRunUpgradeSkipsFreshInit(t *testing.T) {
	service := NewMariaDBService(tempPaths(t))

	runUpgrade, err := service.shouldRunUpgrade("10.11.16", true)
	if err != nil {
		t.Fatalf("shouldRunUpgrade returned error: %v", err)
	}
	if runUpgrade {
		t.Fatal("expected fresh init to skip MariaDB upgrade")
	}
}

func TestShouldRunUpgradeSkipsWhenMariaDBUpgradeInfoMatchesVersion(t *testing.T) {
	paths := tempPaths(t)
	if err := os.MkdirAll(paths.MariaDBDataDir, 0o700); err != nil {
		t.Fatalf("mkdir mariadb data dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(paths.MariaDBDataDir, "mysql_upgrade_info"), []byte("10.11.16-MariaDB\n"), 0o600); err != nil {
		t.Fatalf("write mysql_upgrade_info: %v", err)
	}

	service := NewMariaDBService(paths)
	runUpgrade, err := service.shouldRunUpgrade("10.11.16", false)
	if err != nil {
		t.Fatalf("shouldRunUpgrade returned error: %v", err)
	}
	if runUpgrade {
		t.Fatal("expected matching mysql_upgrade_info to skip upgrade")
	}
}

func TestShouldRunUpgradeRunsWhenNoMarkerExists(t *testing.T) {
	paths := tempPaths(t)
	if err := os.MkdirAll(paths.MariaDBDataDir, 0o700); err != nil {
		t.Fatalf("mkdir mariadb data dir: %v", err)
	}

	service := NewMariaDBService(paths)
	runUpgrade, err := service.shouldRunUpgrade("10.11.16", false)
	if err != nil {
		t.Fatalf("shouldRunUpgrade returned error: %v", err)
	}
	if !runUpgrade {
		t.Fatal("expected missing upgrade markers to require upgrade")
	}
}

func TestMarkUpgradeCompleteWritesNestStamp(t *testing.T) {
	paths := tempPaths(t)
	if err := os.MkdirAll(paths.MariaDBDataDir, 0o700); err != nil {
		t.Fatalf("mkdir mariadb data dir: %v", err)
	}

	service := NewMariaDBService(paths)
	if err := service.markUpgradeComplete("10.11.16"); err != nil {
		t.Fatalf("markUpgradeComplete returned error: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(paths.MariaDBDataDir, ".nest-upgraded-version"))
	if err != nil {
		t.Fatalf("read upgrade stamp: %v", err)
	}
	if string(data) != "10.11.16\n" {
		t.Fatalf("expected upgrade stamp to contain version, got %q", string(data))
	}
}

func TestVersionMatchesRecordedUpgrade(t *testing.T) {
	cases := []struct {
		name     string
		version  string
		recorded string
		match    bool
	}{
		{name: "exact", version: "10.11.16", recorded: "10.11.16", match: true},
		{name: "mariadb suffix", version: "10.11.16", recorded: "10.11.16-MariaDB", match: true},
		{name: "mismatch", version: "10.11.16", recorded: "10.11.15-MariaDB", match: false},
		{name: "empty recorded", version: "10.11.16", recorded: "", match: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if match := versionMatchesRecordedUpgrade(tc.version, tc.recorded); match != tc.match {
				t.Fatalf("expected %t, got %t", tc.match, match)
			}
		})
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
