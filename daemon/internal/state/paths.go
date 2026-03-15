package state

import (
	"os"
	"path/filepath"
)

const (
	AppName        = "Nest"
	SocketFilename = "nest.sock"
)

type Paths struct {
	HomeDir             string
	BaseDir             string
	BinDir              string
	VersionsDir         string
	PHPVersionsDir      string
	MariaDBVersionsDir  string
	ConfigDir           string
	SnippetsDir         string
	LogsDir             string
	RunDir              string
	DataDir             string
	SocketPath          string
	SitesPath           string
	SettingsPath        string
	CaddyfilePath       string
	SecurityConfPath    string
	PHPIniPath          string
	FrankenPHPLogPath   string
	FrankenPHPPIDPath   string
	MariaDBConfigPath   string
	MariaDBLogPath      string
	MariaDBPIDPath      string
	MariaDBSocketPath   string
	MariaDBDataDir      string
	ComposerWrapperPath string
	ComposerPharPath    string
}

func DefaultPaths() (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, err
	}

	base := filepath.Join(home, "Library", "Application Support", AppName)
	configDir := filepath.Join(base, "config")
	paths := Paths{
		HomeDir:             home,
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
		SocketPath:          filepath.Join(base, "run", SocketFilename),
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

	return paths, nil
}

func (p Paths) Ensure() error {
	for _, dir := range []string{
		p.BaseDir,
		p.BinDir,
		p.VersionsDir,
		p.PHPVersionsDir,
		p.MariaDBVersionsDir,
		p.ConfigDir,
		p.SnippetsDir,
		p.LogsDir,
		p.RunDir,
		p.DataDir,
		p.MariaDBDataDir,
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}

	return nil
}

func (p Paths) ActivePHPPath() string {
	return filepath.Join(p.BinDir, "php")
}

func (p Paths) FrankenPHPPath() string {
	return filepath.Join(p.BinDir, "frankenphp")
}

func (p Paths) ActiveMariaDBDir() string {
	return filepath.Join(p.MariaDBVersionsDir, "current")
}

func (p Paths) MariaDBServerPath() string {
	return filepath.Join(p.ActiveMariaDBDir(), "bin", "mariadbd")
}

func (p Paths) MariaDBClientPath() string {
	return filepath.Join(p.ActiveMariaDBDir(), "bin", "mysql")
}

func (p Paths) MariaDBDumpPath() string {
	return filepath.Join(p.ActiveMariaDBDir(), "bin", "mysqldump")
}

func (p Paths) MariaDBAdminPath() string {
	return filepath.Join(p.ActiveMariaDBDir(), "bin", "mariadb-admin")
}

func (p Paths) MariaDBUpgradePath() string {
	return filepath.Join(p.ActiveMariaDBDir(), "bin", "mariadb-upgrade")
}

func (p Paths) MariaDBInstallDBPath() string {
	return filepath.Join(p.ActiveMariaDBDir(), "scripts", "mariadb-install-db")
}

func (p Paths) MySQLSymlinkPath() string {
	return filepath.Join(p.BinDir, "mysql")
}

func (p Paths) MySQLDumpSymlinkPath() string {
	return filepath.Join(p.BinDir, "mysqldump")
}

func (p Paths) MariaDBSymlinkPath() string {
	return filepath.Join(p.BinDir, "mariadb")
}

func (p Paths) MariaDBAdminSymlinkPath() string {
	return filepath.Join(p.BinDir, "mariadb-admin")
}

func (p Paths) PHPAppSnippetPath() string {
	return filepath.Join(p.SnippetsDir, "php-app")
}

func (p Paths) LaravelAppSnippetPath() string {
	return filepath.Join(p.SnippetsDir, "laravel-app")
}
