package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/xcrap/nest/daemon/internal/state"
)

func TestEnsureUpgradesLegacyPHPAppSnippet(t *testing.T) {
	paths := tempPaths(t)
	store := NewStore(paths)
	if err := store.Ensure(); err != nil {
		t.Fatalf("ensure store: %v", err)
	}

	if err := os.WriteFile(paths.PHPAppSnippetPath(), []byte(LegacyPHPAppSnippet), 0o644); err != nil {
		t.Fatalf("seed legacy snippet: %v", err)
	}

	if err := store.Ensure(); err != nil {
		t.Fatalf("re-run ensure: %v", err)
	}

	content, err := os.ReadFile(paths.PHPAppSnippetPath())
	if err != nil {
		t.Fatalf("read upgraded snippet: %v", err)
	}
	if string(content) != DefaultPHPAppSnippet {
		t.Fatalf("expected upgraded php snippet, got %q", string(content))
	}
}

func TestEnsurePreservesCustomizedPHPAppSnippet(t *testing.T) {
	paths := tempPaths(t)
	store := NewStore(paths)
	if err := store.Ensure(); err != nil {
		t.Fatalf("ensure store: %v", err)
	}

	customSnippet := "(php-app) {\n    respond \"custom\"\n}\n"
	if err := os.WriteFile(paths.PHPAppSnippetPath(), []byte(customSnippet), 0o644); err != nil {
		t.Fatalf("seed custom snippet: %v", err)
	}

	if err := store.Ensure(); err != nil {
		t.Fatalf("re-run ensure: %v", err)
	}

	content, err := os.ReadFile(paths.PHPAppSnippetPath())
	if err != nil {
		t.Fatalf("read custom snippet: %v", err)
	}
	if string(content) != customSnippet {
		t.Fatalf("expected custom snippet to be preserved, got %q", string(content))
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
