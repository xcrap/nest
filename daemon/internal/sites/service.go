package sites

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"strings"
	"time"

	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/state"
)

type Service struct {
	paths state.Paths
	store *config.Store
}

type CreateInput struct {
	Name         string `json:"name"`
	Domain       string `json:"domain"`
	RootPath     string `json:"rootPath"`
	PHPVersion   string `json:"phpVersion"`
	HTTPSEnabled bool   `json:"httpsEnabled"`
}

type UpdateInput struct {
	Name         *string `json:"name"`
	Domain       *string `json:"domain"`
	RootPath     *string `json:"rootPath"`
	PHPVersion   *string `json:"phpVersion"`
	HTTPSEnabled *bool   `json:"httpsEnabled"`
}

func NewService(paths state.Paths, store *config.Store) *Service {
	return &Service{
		paths: paths,
		store: store,
	}
}

func (s *Service) List() ([]config.Site, error) {
	return s.store.LoadSites()
}

func (s *Service) Create(input CreateInput) (config.Site, error) {
	if strings.TrimSpace(input.Name) == "" {
		return config.Site{}, errors.New("site name is required")
	}
	if strings.TrimSpace(input.Domain) == "" {
		return config.Site{}, errors.New("domain is required")
	}
	if strings.TrimSpace(input.RootPath) == "" {
		return config.Site{}, errors.New("root path is required")
	}
	if _, err := os.Stat(input.RootPath); err != nil {
		return config.Site{}, err
	}

	sites, err := s.store.LoadSites()
	if err != nil {
		return config.Site{}, err
	}
	for _, existing := range sites {
		if existing.Domain == input.Domain {
			return config.Site{}, errors.New("domain already exists")
		}
	}

	settings, err := s.store.LoadSettings()
	if err != nil {
		return config.Site{}, err
	}

	now := time.Now().UTC()
	site := config.Site{
		ID:           randomID(),
		Name:         input.Name,
		Domain:       strings.ToLower(input.Domain),
		RootPath:     input.RootPath,
		Status:       "stopped",
		HTTPSEnabled: input.HTTPSEnabled,
		PHPVersion:   firstNonEmpty(input.PHPVersion, settings.ActivePHPVersion),
		CreatedAt:    now,
		UpdatedAt:    now,
	}

	sites = append(sites, site)
	if err := s.store.SaveSites(sites); err != nil {
		return config.Site{}, err
	}
	if err := s.RewriteCaddyfile(); err != nil {
		return config.Site{}, err
	}

	return site, nil
}

func (s *Service) Update(id string, input UpdateInput) (config.Site, error) {
	sites, err := s.store.LoadSites()
	if err != nil {
		return config.Site{}, err
	}

	index := -1
	for i := range sites {
		if sites[i].ID == id {
			index = i
			break
		}
	}
	if index == -1 {
		return config.Site{}, errors.New("site not found")
	}

	if input.Name != nil {
		sites[index].Name = strings.TrimSpace(*input.Name)
	}
	if input.Domain != nil {
		sites[index].Domain = strings.ToLower(strings.TrimSpace(*input.Domain))
	}
	if input.RootPath != nil {
		sites[index].RootPath = strings.TrimSpace(*input.RootPath)
	}
	if input.PHPVersion != nil {
		sites[index].PHPVersion = strings.TrimSpace(*input.PHPVersion)
	}
	if input.HTTPSEnabled != nil {
		sites[index].HTTPSEnabled = *input.HTTPSEnabled
	}
	sites[index].UpdatedAt = time.Now().UTC()

	if err := s.store.SaveSites(sites); err != nil {
		return config.Site{}, err
	}
	if err := s.RewriteCaddyfile(); err != nil {
		return config.Site{}, err
	}

	return sites[index], nil
}

func (s *Service) Delete(id string) error {
	sites, err := s.store.LoadSites()
	if err != nil {
		return err
	}

	filtered := make([]config.Site, 0, len(sites))
	found := false
	for _, site := range sites {
		if site.ID == id {
			found = true
			continue
		}
		filtered = append(filtered, site)
	}
	if !found {
		return errors.New("site not found")
	}

	if err := s.store.SaveSites(filtered); err != nil {
		return err
	}
	return s.RewriteCaddyfile()
}

func (s *Service) SetStatus(id, status string) (config.Site, error) {
	sites, err := s.store.LoadSites()
	if err != nil {
		return config.Site{}, err
	}

	for i := range sites {
		if sites[i].ID != id {
			continue
		}
		sites[i].Status = status
		sites[i].UpdatedAt = time.Now().UTC()
		if err := s.store.SaveSites(sites); err != nil {
			return config.Site{}, err
		}
		if err := s.RewriteCaddyfile(); err != nil {
			return config.Site{}, err
		}
		return sites[i], nil
	}

	return config.Site{}, errors.New("site not found")
}

func (s *Service) RewriteCaddyfile() error {
	sites, err := s.store.LoadSites()
	if err != nil {
		return err
	}
	contents := GenerateCaddyfile(sites, s.paths.FrankenPHPLogPath)
	return os.WriteFile(s.paths.CaddyfilePath, []byte(contents), 0o644)
}

func randomID() string {
	buffer := make([]byte, 6)
	if _, err := rand.Read(buffer); err != nil {
		return time.Now().UTC().Format("20060102150405")
	}
	return hex.EncodeToString(buffer)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
