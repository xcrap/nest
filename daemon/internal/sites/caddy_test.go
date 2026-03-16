package sites

import (
	"fmt"
	"os"
	"path/filepath"
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
			RootPath:     "/tmp/alpha",
			DocumentRoot: "public",
			Status:       "running",
			CreatedAt:    now,
			UpdatedAt:    now,
		},
		{
			ID:           "two",
			Domain:       "beta.test",
			RootPath:     "/tmp/beta",
			DocumentRoot: "public",
			Status:       "stopped",
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
			ID:           "one",
			Domain:       "php-project.test",
			RootPath:     "/tmp/php-project",
			DocumentRoot: "public",
			Status:       "running",
			CreatedAt:    now,
			UpdatedAt:    now,
		},
		{
			ID:           "two",
			Domain:       "root-project.test",
			RootPath:     "/tmp/root-project",
			DocumentRoot: ".",
			Status:       "running",
			CreatedAt:    now,
			UpdatedAt:    now,
		},
	}, "/tmp/frankenphp.log")

	if !strings.Contains(output, "import snippets/*") {
		t.Fatalf("expected snippets import: %s", output)
	}
	if !strings.Contains(output, "import php-app php-project.test /tmp/php-project /tmp/php-project/public") {
		t.Fatalf("expected php-app import: %s", output)
	}
	if !strings.Contains(output, "import php-app root-project.test /tmp/root-project /tmp/root-project") {
		t.Fatalf("expected root import: %s", output)
	}
}

func TestGenerateCaddyfileDefaultsToPhpApp(t *testing.T) {
	now := time.Now().UTC()
	rootPath := t.TempDir()
	if err := os.MkdirAll(filepath.Join(rootPath, "public"), 0o755); err != nil {
		t.Fatalf("mkdir public dir: %v", err)
	}
	output := GenerateCaddyfile([]config.Site{
		{
			ID:        "one",
			Domain:    "project.test",
			RootPath:  rootPath,
			Status:    "running",
			CreatedAt: now,
			UpdatedAt: now,
		},
	}, "/tmp/frankenphp.log")

	if !strings.Contains(output, fmt.Sprintf("import php-app project.test %s %s", rootPath, filepath.Join(rootPath, "public"))) {
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
