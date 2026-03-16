package composer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/installutil"
	"github.com/xcrap/nest/daemon/internal/state"
)

const defaultSourceURL = "https://getcomposer.org/download/latest-stable/composer.phar"

var (
	httpClient         = http.DefaultClient
	downloadToFile     = installutil.DownloadToFile
	resolveVersion     = inspectVersion
	fetchRelease       = defaultFetchLatestRelease
	composerVersionExp = regexp.MustCompile(`Composer version ([^ ]+)`)
)

type Release struct {
	Version     string
	SourceURL   string
	ChecksumURL string
	SHA256      string
}

func SourceURL() string {
	if override := strings.TrimSpace(os.Getenv("NEST_COMPOSER_URL")); override != "" {
		return override
	}
	return defaultSourceURL
}

func ChecksumURL() string {
	if override := strings.TrimSpace(os.Getenv("NEST_COMPOSER_CHECKSUM_URL")); override != "" {
		return override
	}
	return SourceURL() + ".sha256sum"
}

func Detect(ctx context.Context, paths state.Paths) (config.ComposerRuntime, error) {
	runtime := config.ComposerRuntime{
		Status:      "not_installed",
		SourceURL:   SourceURL(),
		ChecksumURL: ChecksumURL(),
		PharPath:    paths.ComposerPharPath,
		WrapperPath: paths.ComposerWrapperPath,
		BackupPath:  paths.ComposerBackupPath,
	}

	if info, err := os.Stat(paths.ComposerPharPath); err == nil {
		runtime.Installed = true
		runtime.Status = "installed"
		runtime.InstalledAt = info.ModTime().UTC()

		checksum, checksumErr := fileSHA256(paths.ComposerPharPath)
		if checksumErr != nil {
			runtime.Status = "error"
			runtime.LastError = checksumErr.Error()
		} else {
			runtime.InstalledChecksum = checksum
		}

		if _, err := os.Stat(paths.ComposerWrapperPath); err == nil {
			runtime.WrapperPresent = true
		}

		if phpPath, err := activePHPPath(paths); err == nil {
			version, versionErr := resolveVersion(ctx, phpPath, paths.ComposerPharPath)
			if versionErr != nil {
				if runtime.LastError == "" {
					runtime.LastError = versionErr.Error()
				}
				runtime.Status = "error"
			} else {
				runtime.InstalledVersion = version
			}
		} else if runtime.LastError == "" {
			runtime.LastError = err.Error()
		}
	} else if !os.IsNotExist(err) {
		return runtime, err
	}

	if _, err := os.Stat(paths.ComposerBackupPath); err == nil {
		runtime.BackupAvailable = true
	}

	return runtime, nil
}

func CheckForUpdates(ctx context.Context, paths state.Paths) (config.ComposerRuntime, error) {
	runtime, err := Detect(ctx, paths)
	if err != nil {
		return runtime, err
	}

	release, tempPath, err := fetchRelease(ctx, paths)
	if tempPath != "" {
		_ = os.Remove(tempPath)
	}
	if err != nil {
		runtime.LastError = err.Error()
		return runtime, nil
	}

	runtime.LatestVersion = release.Version
	runtime.LatestChecksum = release.SHA256
	runtime.UpdateAvailable = !runtime.Installed || !strings.EqualFold(runtime.InstalledChecksum, release.SHA256)
	return runtime, nil
}

func Install(ctx context.Context, paths state.Paths) (config.ComposerRuntime, error) {
	if err := os.MkdirAll(filepath.Dir(paths.ComposerPharPath), 0o700); err != nil {
		return config.ComposerRuntime{}, err
	}

	release, tempPath, err := fetchRelease(ctx, paths)
	if err != nil {
		return config.ComposerRuntime{}, err
	}
	defer func() {
		if tempPath != "" {
			_ = os.Remove(tempPath)
		}
	}()

	if err := replaceWithBackup(paths.ComposerPharPath, paths.ComposerBackupPath, tempPath, 0o644); err != nil {
		return config.ComposerRuntime{}, err
	}
	tempPath = ""

	runtime, err := Detect(ctx, paths)
	if err != nil {
		return runtime, err
	}
	runtime.LatestVersion = release.Version
	runtime.LatestChecksum = release.SHA256
	runtime.UpdateAvailable = false
	return runtime, nil
}

func Rollback(ctx context.Context, paths state.Paths) (config.ComposerRuntime, error) {
	if _, err := os.Stat(paths.ComposerBackupPath); err != nil {
		if os.IsNotExist(err) {
			return config.ComposerRuntime{}, fmt.Errorf("composer rollback is unavailable because %s does not exist", paths.ComposerBackupPath)
		}
		return config.ComposerRuntime{}, err
	}

	phpPath, err := activePHPPath(paths)
	if err != nil {
		return config.ComposerRuntime{}, err
	}
	if _, err := resolveVersion(ctx, phpPath, paths.ComposerBackupPath); err != nil {
		return config.ComposerRuntime{}, fmt.Errorf("composer rollback backup is invalid: %w", err)
	}

	tempPath := paths.ComposerPharPath + ".rollback"
	_ = os.Remove(tempPath)
	if _, err := os.Stat(paths.ComposerPharPath); err == nil {
		if err := os.Rename(paths.ComposerPharPath, tempPath); err != nil {
			return config.ComposerRuntime{}, err
		}
	}

	if err := copyFile(paths.ComposerBackupPath, paths.ComposerPharPath, 0o644); err != nil {
		if _, statErr := os.Stat(tempPath); statErr == nil {
			_ = os.Rename(tempPath, paths.ComposerPharPath)
		}
		return config.ComposerRuntime{}, err
	}

	if _, err := os.Stat(tempPath); err == nil {
		_ = os.Remove(paths.ComposerBackupPath)
		_ = os.Rename(tempPath, paths.ComposerBackupPath)
	}

	return Detect(ctx, paths)
}

func defaultFetchLatestRelease(ctx context.Context, paths state.Paths) (Release, string, error) {
	checksum, err := fetchLatestChecksum(ctx)
	if err != nil {
		return Release{}, "", err
	}

	if err := os.MkdirAll(filepath.Dir(paths.ComposerPharPath), 0o700); err != nil {
		return Release{}, "", err
	}

	tempFile, err := os.CreateTemp(filepath.Dir(paths.ComposerPharPath), "composer-*.phar")
	if err != nil {
		return Release{}, "", err
	}
	tempPath := tempFile.Name()
	if err := tempFile.Close(); err != nil {
		_ = os.Remove(tempPath)
		return Release{}, "", err
	}

	if err := downloadToFile(ctx, SourceURL(), tempPath, checksum); err != nil {
		_ = os.Remove(tempPath)
		return Release{}, "", err
	}

	phpPath, err := activePHPPath(paths)
	if err != nil {
		_ = os.Remove(tempPath)
		return Release{}, "", err
	}

	version, err := resolveVersion(ctx, phpPath, tempPath)
	if err != nil {
		_ = os.Remove(tempPath)
		return Release{}, "", err
	}

	return Release{
		Version:     version,
		SourceURL:   SourceURL(),
		ChecksumURL: ChecksumURL(),
		SHA256:      checksum,
	}, tempPath, nil
}

func fetchLatestChecksum(ctx context.Context) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, ChecksumURL(), nil)
	if err != nil {
		return "", err
	}

	response, err := httpClient.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("composer checksum download failed: %s", response.Status)
	}

	body, err := io.ReadAll(response.Body)
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(body))
	if len(fields) == 0 {
		return "", fmt.Errorf("composer checksum response was empty")
	}
	return fields[0], nil
}

func inspectVersion(ctx context.Context, phpPath, pharPath string) (string, error) {
	command := exec.CommandContext(ctx, phpPath, pharPath, "--no-interaction", "--no-ansi", "--version")
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("composer version probe failed: %s", strings.TrimSpace(string(output)))
	}

	matches := composerVersionExp.FindStringSubmatch(string(output))
	if len(matches) < 2 {
		return "", fmt.Errorf("composer version probe returned unexpected output: %s", strings.TrimSpace(string(output)))
	}
	return matches[1], nil
}

func activePHPPath(paths state.Paths) (string, error) {
	if _, err := os.Stat(paths.ActivePHPPath()); err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("managed PHP runtime is required before installing Composer")
		}
		return "", err
	}
	return paths.ActivePHPPath(), nil
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func replaceWithBackup(destination, backupPath, tempPath string, mode os.FileMode) error {
	_ = os.Remove(backupPath)

	if _, err := os.Stat(destination); err == nil {
		if err := os.Rename(destination, backupPath); err != nil {
			return err
		}
	}

	if err := os.Chmod(tempPath, mode); err != nil {
		if _, statErr := os.Stat(backupPath); statErr == nil {
			_ = os.Rename(backupPath, destination)
		}
		return err
	}

	if err := os.Rename(tempPath, destination); err != nil {
		if _, statErr := os.Stat(backupPath); statErr == nil {
			_ = os.Rename(backupPath, destination)
		}
		return err
	}

	return nil
}

func copyFile(source, destination string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()

	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}

	if _, err := io.Copy(output, input); err != nil {
		output.Close()
		return err
	}
	return output.Close()
}
