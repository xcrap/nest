package sites

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
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
	DocumentRoot string `json:"documentRoot"`
	PHPVersion   string `json:"phpVersion"`
	HTTPSEnabled bool   `json:"httpsEnabled"`
}

type UpdateInput struct {
	Name         *string `json:"name"`
	Domain       *string `json:"domain"`
	RootPath     *string `json:"rootPath"`
	DocumentRoot *string `json:"documentRoot"`
	PHPVersion   *string `json:"phpVersion"`
	HTTPSEnabled *bool   `json:"httpsEnabled"`
}

type ImportResult struct {
	Imported int      `json:"imported"`
	Skipped  []string `json:"skipped"`
}

const defaultDocumentRoot = "public"

func NewService(paths state.Paths, store *config.Store) *Service {
	return &Service{
		paths: paths,
		store: store,
	}
}

func (s *Service) List() ([]config.Site, error) {
	sites, err := s.store.LoadSites()
	if err != nil {
		return nil, err
	}
	normalized, changed := normalizeSites(sites)
	if changed {
		if err := s.store.SaveSites(normalized); err != nil {
			return nil, err
		}
	}
	sort.Slice(normalized, func(i, j int) bool {
		left := normalized[i]
		right := normalized[j]
		if strings.EqualFold(left.Name, right.Name) {
			return strings.ToLower(left.Domain) < strings.ToLower(right.Domain)
		}
		return strings.ToLower(left.Name) < strings.ToLower(right.Name)
	})
	return normalized, nil
}

func (s *Service) Create(input CreateInput) (config.Site, error) {
	if strings.TrimSpace(input.Name) == "" {
		return config.Site{}, errors.New("site name is required")
	}
	if strings.TrimSpace(input.Domain) == "" {
		return config.Site{}, errors.New("domain is required")
	}
	if strings.TrimSpace(input.RootPath) == "" {
		return config.Site{}, errors.New("project folder is required")
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
	documentRoot, err := validateDocumentRoot(input.RootPath, input.DocumentRoot)
	if err != nil {
		return config.Site{}, err
	}

	now := time.Now().UTC()
	site := config.Site{
		ID:           randomID(),
		Name:         input.Name,
		Domain:       strings.ToLower(input.Domain),
		RootPath:     input.RootPath,
		DocumentRoot: documentRoot,
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
	sites, changed := normalizeSites(sites)
	if changed {
		if err := s.store.SaveSites(sites); err != nil {
			return config.Site{}, err
		}
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
		name := strings.TrimSpace(*input.Name)
		if name == "" {
			return config.Site{}, errors.New("site name is required")
		}
		sites[index].Name = name
	}
	if input.Domain != nil {
		domain := strings.ToLower(strings.TrimSpace(*input.Domain))
		if domain == "" {
			return config.Site{}, errors.New("domain is required")
		}
		for i, existing := range sites {
			if i != index && existing.Domain == domain {
				return config.Site{}, errors.New("domain already exists")
			}
		}
		sites[index].Domain = domain
	}
	if input.RootPath != nil {
		rootPath := strings.TrimSpace(*input.RootPath)
		if rootPath == "" {
			return config.Site{}, errors.New("project folder is required")
		}
		if _, err := os.Stat(rootPath); err != nil {
			return config.Site{}, err
		}
		sites[index].RootPath = rootPath
	}
	if input.DocumentRoot != nil {
		sites[index].DocumentRoot = strings.TrimSpace(*input.DocumentRoot)
	}
	if input.PHPVersion != nil {
		phpVersion := strings.TrimSpace(*input.PHPVersion)
		if phpVersion == "" {
			return config.Site{}, errors.New("php version is required")
		}
		sites[index].PHPVersion = phpVersion
	}
	if input.HTTPSEnabled != nil {
		sites[index].HTTPSEnabled = *input.HTTPSEnabled
	}
	documentRoot, err := validateDocumentRoot(sites[index].RootPath, sites[index].DocumentRoot)
	if err != nil {
		return config.Site{}, err
	}
	sites[index].DocumentRoot = documentRoot
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
	sites, changed := normalizeSites(sites)
	if changed {
		if err := s.store.SaveSites(sites); err != nil {
			return err
		}
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
	sites, changed := normalizeSites(sites)
	if changed {
		if err := s.store.SaveSites(sites); err != nil {
			return config.Site{}, err
		}
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

func (s *Service) Import(inputs []CreateInput) (ImportResult, error) {
	sites, err := s.store.LoadSites()
	if err != nil {
		return ImportResult{}, err
	}

	settings, err := s.store.LoadSettings()
	if err != nil {
		return ImportResult{}, err
	}

	domains := make(map[string]bool, len(sites))
	for _, site := range sites {
		domains[strings.ToLower(site.Domain)] = true
	}

	var result ImportResult
	for _, input := range inputs {
		domain := strings.ToLower(strings.TrimSpace(input.Domain))
		if domain == "" || strings.TrimSpace(input.Name) == "" || strings.TrimSpace(input.RootPath) == "" {
			result.Skipped = append(result.Skipped, domain)
			continue
		}
		if domains[domain] {
			result.Skipped = append(result.Skipped, domain)
			continue
		}

		documentRoot := strings.TrimSpace(input.DocumentRoot)
		if documentRoot == "" {
			documentRoot = inferredDocumentRoot(input.RootPath)
		}

		now := time.Now().UTC()
		site := config.Site{
			ID:           randomID(),
			Name:         input.Name,
			Domain:       domain,
			RootPath:     input.RootPath,
			DocumentRoot: documentRoot,
			Status:       "stopped",
			HTTPSEnabled: input.HTTPSEnabled,
			PHPVersion:   firstNonEmpty(input.PHPVersion, settings.ActivePHPVersion),
			CreatedAt:    now,
			UpdatedAt:    now,
		}

		sites = append(sites, site)
		domains[domain] = true
		result.Imported++
	}

	if result.Imported > 0 {
		if err := s.store.SaveSites(sites); err != nil {
			return ImportResult{}, err
		}
		if err := s.RewriteCaddyfile(); err != nil {
			return ImportResult{}, err
		}
	}

	return result, nil
}

func (s *Service) RewriteCaddyfile() error {
	sites, err := s.store.LoadSites()
	if err != nil {
		return err
	}
	sites, changed := normalizeSites(sites)
	if changed {
		if err := s.store.SaveSites(sites); err != nil {
			return err
		}
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

func normalizeSites(sites []config.Site) ([]config.Site, bool) {
	normalized := make([]config.Site, len(sites))
	changed := false
	for index, site := range sites {
		normalized[index] = site
		if strings.TrimSpace(site.DocumentRoot) != "" {
			continue
		}
		normalized[index].DocumentRoot = inferredDocumentRoot(site.RootPath)
		changed = true
	}
	return normalized, changed
}

func inferredDocumentRoot(rootPath string) string {
	publicDir := filepath.Join(rootPath, defaultDocumentRoot)
	info, err := os.Stat(publicDir)
	if err == nil && info.IsDir() {
		return defaultDocumentRoot
	}
	return "."
}

func validateDocumentRoot(rootPath, value string) (string, error) {
	documentRoot := strings.TrimSpace(value)
	if documentRoot == "" {
		documentRoot = defaultDocumentRoot
	}
	if filepath.IsAbs(documentRoot) {
		return "", errors.New("document root must be relative to the project folder")
	}
	documentRoot = filepath.Clean(documentRoot)
	if documentRoot == ".." || strings.HasPrefix(documentRoot, ".."+string(os.PathSeparator)) {
		return "", errors.New("document root must stay inside the project folder")
	}
	fullPath := rootPath
	if documentRoot != "." {
		fullPath = filepath.Join(rootPath, documentRoot)
	}
	info, err := os.Stat(fullPath)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("document root must point to a folder")
	}
	return documentRoot, nil
}
