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
			RootPath:     "/tmp/alpha",
			Status:       "running",
			HTTPSEnabled: true,
			CreatedAt:    now,
			UpdatedAt:    now,
		},
		{
			ID:           "two",
			Domain:       "beta.test",
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
}
