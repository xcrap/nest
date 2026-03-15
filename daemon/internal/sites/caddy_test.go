package sites

import (
	"strings"
	"testing"
	"time"

	"github.com/xcrap/nest/daemon/internal/config"
)

func TestGenerateCaddyfileIncludesOnlyRunningSites(t *testing.T) {
	now := time.Now().UTC()
	output := GenerateCaddyfile([]config.Site{
		{
			ID:           "one",
			Domain:       "alpha.test",
			Type:         "php",
			RootPath:     "/tmp/alpha",
			Status:       "running",
			HTTPSEnabled: true,
			CreatedAt:    now,
			UpdatedAt:    now,
		},
		{
			ID:           "two",
			Domain:       "beta.test",
			Type:         "php",
			RootPath:     "/tmp/beta",
			Status:       "stopped",
			HTTPSEnabled: true,
			CreatedAt:    now,
			UpdatedAt:    now,
		},
	}, "/tmp/frankenphp.log")

	if !strings.Contains(output, "alpha.test") {
		t.Fatalf("expected running site in caddyfile: %s", output)
	}
	if strings.Contains(output, "beta.test") {
		t.Fatalf("expected stopped site to be excluded: %s", output)
	}
	if !strings.Contains(output, "localhost {\n\ttls internal\n\trespond 204\n}") {
		t.Fatalf("expected localhost tls endpoint in caddyfile: %s", output)
	}
}

func TestGenerateCaddyfileUsesImportPattern(t *testing.T) {
	now := time.Now().UTC()
	output := GenerateCaddyfile([]config.Site{
		{
			ID:       "one",
			Domain:   "php-project.test",
			Type:     "php",
			RootPath: "/tmp/php-project",
			Status:   "running",
			CreatedAt: now,
			UpdatedAt: now,
		},
		{
			ID:       "two",
			Domain:   "laravel-project.test",
			Type:     "laravel",
			RootPath: "/tmp/laravel-project",
			Status:   "running",
			CreatedAt: now,
			UpdatedAt: now,
		},
	}, "/tmp/frankenphp.log")

	if !strings.Contains(output, "import snippets/*") {
		t.Fatalf("expected snippets import: %s", output)
	}
	if !strings.Contains(output, "import php-app php-project.test /tmp/php-project") {
		t.Fatalf("expected php-app import: %s", output)
	}
	if !strings.Contains(output, "import laravel-app laravel-project.test /tmp/laravel-project") {
		t.Fatalf("expected laravel-app import: %s", output)
	}
}

func TestGenerateCaddyfileDefaultsToPhpApp(t *testing.T) {
	now := time.Now().UTC()
	output := GenerateCaddyfile([]config.Site{
		{
			ID:       "one",
			Domain:   "project.test",
			Type:     "",
			RootPath: "/tmp/project",
			Status:   "running",
			CreatedAt: now,
			UpdatedAt: now,
		},
	}, "/tmp/frankenphp.log")

	if !strings.Contains(output, "import php-app project.test /tmp/project") {
		t.Fatalf("expected default php-app import: %s", output)
	}
}

func TestGenerateCaddyfileIncludesLocalhostWhenNoSitesRun(t *testing.T) {
	output := GenerateCaddyfile(nil, "/tmp/frankenphp.log")

	if !strings.Contains(output, "localhost {\n\ttls internal\n\trespond 204\n}") {
		t.Fatalf("expected localhost tls endpoint in caddyfile: %s", output)
	}
	if !strings.Contains(output, "# No running sites are registered yet.") {
		t.Fatalf("expected empty-state comment in caddyfile: %s", output)
	}
}
