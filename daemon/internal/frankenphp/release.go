package frankenphp

import (
	"context"
	"os"
	"path/filepath"

	"github.com/xcrap/nest/daemon/internal/installutil"
)

type Release struct {
	Version            string
	BinaryURL          string
	SHA256             string
	EmbeddedPHPVersion string
}

func CurrentRelease() Release {
	return Release{
		Version:            "1.12.0",
		BinaryURL:          firstNonEmpty(os.Getenv("NEST_FRANKENPHP_URL"), "https://github.com/php/frankenphp/releases/download/v1.12.0/frankenphp-mac-arm64"),
		SHA256:             firstNonEmpty(os.Getenv("NEST_FRANKENPHP_SHA256"), "8713bad88cb2dfa8b12b26d8ae9a6f3050cd4463491dee46398bda0b46c877b0"),
		EmbeddedPHPVersion: "8.5",
	}
}

func InstallBinary(ctx context.Context, destination string) error {
	release := CurrentRelease()
	tempPath := destination + ".download"
	if err := installutil.DownloadToFile(ctx, release.BinaryURL, tempPath, release.SHA256); err != nil {
		return err
	}
	if err := os.Chmod(tempPath, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	return os.Rename(tempPath, destination)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
