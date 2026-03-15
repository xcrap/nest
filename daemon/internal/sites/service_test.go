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
	if err := os.MkdirAll(filepath.Join(rootPath, "public"), 0o755); err != nil {
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
	if sitesList[0].DocumentRoot != defaultDocumentRoot {
		t.Fatalf("expected default document root, got %+v", sitesList[0])
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

func TestUpdateValidatesAndPersistsSite(t *testing.T) {
	paths := tempPaths(t)
	store := config.NewStore(paths)
	if err := store.Ensure(); err != nil {
		t.Fatalf("ensure store: %v", err)
	}

	firstRoot := filepath.Join(paths.HomeDir, "project-a")
	secondRoot := filepath.Join(paths.HomeDir, "project-b")
	if err := os.MkdirAll(filepath.Join(firstRoot, "public"), 0o755); err != nil {
		t.Fatalf("mkdir first root: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(secondRoot, "public"), 0o755); err != nil {
		t.Fatalf("mkdir second root: %v", err)
	}

	service := NewService(paths, store)
	firstSite, err := service.Create(CreateInput{
		Name:         "Project A",
		Domain:       "project-a.test",
		RootPath:     firstRoot,
		PHPVersion:   "8.5",
		HTTPSEnabled: true,
	})
	if err != nil {
		t.Fatalf("create first site: %v", err)
	}
	if _, err := service.Create(CreateInput{
		Name:         "Project B",
		Domain:       "project-b.test",
		RootPath:     secondRoot,
		PHPVersion:   "8.5",
		HTTPSEnabled: false,
	}); err != nil {
		t.Fatalf("create second site: %v", err)
	}

	newName := "Project A Prime"
	newDomain := "project-prime.test"
	newRoot := secondRoot
	newVersion := "8.4"
	httpsEnabled := false

	updated, err := service.Update(firstSite.ID, UpdateInput{
		Name:         &newName,
		Domain:       &newDomain,
		RootPath:     &newRoot,
		PHPVersion:   &newVersion,
		HTTPSEnabled: &httpsEnabled,
	})
	if err != nil {
		t.Fatalf("update site: %v", err)
	}

	if updated.Name != newName || updated.Domain != newDomain || updated.RootPath != newRoot || updated.PHPVersion != newVersion || updated.HTTPSEnabled != httpsEnabled {
		t.Fatalf("unexpected updated site: %+v", updated)
	}

	duplicateDomain := "project-b.test"
	if _, err := service.Update(firstSite.ID, UpdateInput{Domain: &duplicateDomain}); err == nil {
		t.Fatal("expected duplicate domain to fail")
	}

	emptyName := ""
	if _, err := service.Update(firstSite.ID, UpdateInput{Name: &emptyName}); err == nil {
		t.Fatal("expected empty name to fail")
	}

	missingRoot := filepath.Join(paths.HomeDir, "missing")
	if _, err := service.Update(firstSite.ID, UpdateInput{RootPath: &missingRoot}); err == nil {
		t.Fatal("expected missing root to fail")
	}
}

func TestCreateSupportsProjectRootDocumentRoot(t *testing.T) {
	paths := tempPaths(t)
	store := config.NewStore(paths)
	if err := store.Ensure(); err != nil {
		t.Fatalf("ensure store: %v", err)
	}

	rootPath := filepath.Join(paths.HomeDir, "rooted-project")
	if err := os.MkdirAll(rootPath, 0o755); err != nil {
		t.Fatalf("mkdir site root: %v", err)
	}

	service := NewService(paths, store)
	site, err := service.Create(CreateInput{
		Name:         "Rooted Project",
		Domain:       "rooted.test",
		RootPath:     rootPath,
		DocumentRoot: ".",
		HTTPSEnabled: true,
	})
	if err != nil {
		t.Fatalf("create site: %v", err)
	}
	if site.DocumentRoot != "." {
		t.Fatalf("expected document root '.', got %+v", site)
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
