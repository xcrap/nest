package sites

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/state"
)

func TestCreateAndDeleteSite(t *testing.T) {
	paths := tempPaths(t)
	store := config.NewStore(paths)
	if err := store.Ensure(); err != nil {
		t.Fatalf("ensure store: %v", err)
	}

	rootPath := filepath.Join(paths.HomeDir, "project")
	if err := os.MkdirAll(rootPath, 0o755); err != nil {
		t.Fatalf("mkdir site root: %v", err)
	}

	service := NewService(paths, store)
	site, err := service.Create(CreateInput{
		Name:         "Project",
		Domain:       "project.test",
		RootPath:     rootPath,
		HTTPSEnabled: true,
	})
	if err != nil {
		t.Fatalf("create site: %v", err)
	}

	sitesList, err := service.List()
	if err != nil {
		t.Fatalf("list sites: %v", err)
	}
	if len(sitesList) != 1 || sitesList[0].ID != site.ID {
		t.Fatalf("unexpected sites after create: %+v", sitesList)
	}

	if err := service.Delete(site.ID); err != nil {
		t.Fatalf("delete site: %v", err)
	}

	sitesList, err = service.List()
	if err != nil {
		t.Fatalf("list sites: %v", err)
	}
	if len(sitesList) != 0 {
		t.Fatalf("expected site list to be empty, got %+v", sitesList)
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
