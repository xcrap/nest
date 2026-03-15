package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/xcrap/nest/daemon/internal/state"
)

type Store struct {
	paths state.Paths
}

func NewStore(paths state.Paths) *Store {
	return &Store{paths: paths}
}

func (s *Store) Ensure() error {
	if err := s.paths.Ensure(); err != nil {
		return err
	}

	if _, err := os.Stat(s.paths.SitesPath); errors.Is(err, os.ErrNotExist) {
		if err := s.SaveSites([]Site{}); err != nil {
			return err
		}
	}

	if _, err := os.Stat(s.paths.SettingsPath); errors.Is(err, os.ErrNotExist) {
		if err := s.SaveSettings(DefaultSettings()); err != nil {
			return err
		}
	}

	if _, err := os.Stat(s.paths.CaddyfilePath); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(s.paths.CaddyfilePath, []byte("{\n\thttp_port 8080\n\thttps_port 8443\n\tadmin localhost:2019\n\tlocal_certs\n}\n\nlocalhost {\n\ttls internal\n\trespond 204\n}\n"), 0o644); err != nil {
			return err
		}
	}

	defaults := []struct {
		path    string
		content string
		legacy  []string
	}{
		{path: s.paths.SecurityConfPath, content: DefaultSecurityConf},
		{path: s.paths.PHPIniPath, content: DefaultPHPIni},
		{path: s.paths.PHPAppSnippetPath(), content: DefaultPHPAppSnippet, legacy: []string{LegacyPHPAppSnippet}},
	}
	for _, file := range defaults {
		if err := ensureManagedFile(file.path, file.content, file.legacy...); err != nil {
			return err
		}
	}

	return nil
}

func (s *Store) LoadConfigFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (s *Store) SaveConfigFile(path string, content string) error {
	return os.WriteFile(path, []byte(content), 0o644)
}

func (s *Store) LoadSites() ([]Site, error) {
	var sites []Site
	if err := readJSONFile(s.paths.SitesPath, &sites); err != nil {
		return nil, err
	}
	return sites, nil
}

func (s *Store) SaveSites(sites []Site) error {
	return writeJSONFile(s.paths.SitesPath, sites)
}

func (s *Store) LoadSettings() (Settings, error) {
	settings := DefaultSettings()
	if err := readJSONFile(s.paths.SettingsPath, &settings); err != nil {
		return Settings{}, err
	}
	return settings, nil
}

func (s *Store) SaveSettings(settings Settings) error {
	return writeJSONFile(s.paths.SettingsPath, settings)
}

const DefaultSecurityConf = `header {
    Referrer-Policy no-referrer-when-downgrade
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Xss-Protection "1; mode=block"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Content-Security-Policy "upgrade-insecure-requests"
    -Server Caddy
}
`

const DefaultPHPIni = `[PHP]
error_reporting = E_ALL & ~E_DEPRECATED
log_errors = On
error_log = php_errors.log
`

const DefaultPHPAppSnippet = `(php-app) {
    {args[0]} {
        import ../security.conf

        root * {args[2]}

        @blocked path */.* *.sql *.log *.bak *.env
        respond @blocked 404

        encode zstd gzip

        php_server
        file_server
    }
}
`

const LegacyPHPAppSnippet = `(php-app) {
    {args[0]} {
        import ../security.conf

        root * {args[1]}/public

        @blocked path */.* *.sql *.log *.bak *.env
        respond @blocked 404

        encode zstd gzip

        php_server {
            env PHP_INI_log_errors 1
        }
        file_server
    }
}
`

func readJSONFile(path string, target any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if len(data) == 0 {
		return nil
	}
	return json.Unmarshal(data, target)
}

func writeJSONFile(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	tempFile := path + ".tmp"
	if err := os.WriteFile(tempFile, data, 0o644); err != nil {
		return err
	}

	return os.Rename(tempFile, filepath.Clean(path))
}

func ensureManagedFile(path, content string, legacyContents ...string) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return os.WriteFile(path, []byte(content), 0o644)
	}
	if err != nil {
		return err
	}

	current := string(data)
	if current == content {
		return nil
	}
	for _, legacy := range legacyContents {
		if current == legacy {
			return os.WriteFile(path, []byte(content), 0o644)
		}
	}
	return nil
}
