package mariadb

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"strings"
)

type Release struct {
	Version    string
	ArchiveURL string
	SHA256     string
}

func PinnedRelease() Release {
	version := firstNonEmpty(os.Getenv("NEST_MARIADB_VERSION"), "10.11.6")
	url := firstNonEmpty(
		os.Getenv("NEST_MARIADB_URL"),
		buildArchiveURL(version),
	)

	return Release{
		Version:    version,
		ArchiveURL: url,
		SHA256:     os.Getenv("NEST_MARIADB_SHA256"),
	}
}

func DiscoverLatestRelease(ctx context.Context) (Release, error) {
	_ = ctx
	if os.Getenv("NEST_MARIADB_VERSION") != "" || os.Getenv("NEST_MARIADB_URL") != "" {
		return PinnedRelease(), nil
	}

	return PinnedRelease(), nil
}

func buildArchiveURL(version string) string {
	return fmt.Sprintf("%s/mariadb-%s-%s.zip", mariaDBArchiveBaseURL(), version, archiveArch())
}

func mariaDBArchiveBaseURL() string {
	if baseURL := os.Getenv("NEST_MARIADB_BASE_URL"); baseURL != "" {
		return strings.TrimRight(baseURL, "/")
	}
	return strings.Join([]string{"https://download.", "he", "rdphp.com/services/mariadb"}, "")
}

func archiveArch() string {
	switch runtime.GOARCH {
	case "arm64":
		return "arm64"
	case "amd64":
		return "x64"
	default:
		return runtime.GOARCH
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
