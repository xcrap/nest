package mariadb

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

const defaultFormula = "mariadb@10.11"

var versionPattern = regexp.MustCompile(`\b(\d+\.\d+\.\d+)\b`)

type Runtime struct {
	Formula          string
	Prefix           string
	Installed        bool
	Pinned           bool
	InstalledVersion string
}

func Formula() string {
	if value := strings.TrimSpace(os.Getenv("NEST_MARIADB_FORMULA")); value != "" {
		return value
	}
	return defaultFormula
}

func Detect(ctx context.Context) (Runtime, error) {
	formula := Formula()
	runtime := Runtime{Formula: formula}

	brewPath, err := brewBinary()
	if err != nil {
		return runtime, fmt.Errorf("homebrew is required to manage MariaDB")
	}

	installed, version, err := installedVersion(ctx, brewPath, formula)
	if err != nil {
		return runtime, err
	}
	runtime.Installed = installed
	runtime.InstalledVersion = version
	runtime.Pinned, _ = isPinned(ctx, brewPath, formula)
	if !installed {
		return runtime, nil
	}

	prefix, err := prefix(ctx, brewPath, formula)
	if err != nil {
		return runtime, err
	}
	runtime.Prefix = prefix

	if version == "" {
		version, _ = binaryVersion(filepath.Join(prefix, "bin", "mariadbd"))
		runtime.InstalledVersion = version
	}

	return runtime, nil
}

func EnsureInstalled(ctx context.Context, progress func(string)) (Runtime, error) {
	brewPath, err := brewBinary()
	if err != nil {
		return Runtime{Formula: Formula()}, fmt.Errorf("homebrew is required to manage MariaDB")
	}

	runtime, err := Detect(ctx)
	if err != nil {
		return runtime, err
	}

	if !runtime.Installed {
		if progress != nil {
			progress("Installing Homebrew formula " + runtime.Formula)
		}
		if err := runBrew(ctx, brewPath, "install", runtime.Formula); err != nil {
			return runtime, err
		}
	}

	if progress != nil {
		progress("Pinning Homebrew formula " + runtime.Formula)
	}
	if err := runBrew(ctx, brewPath, "pin", runtime.Formula); err != nil {
		return runtime, err
	}

	return Detect(ctx)
}

func ServerPath(prefix string) string {
	return filepath.Join(prefix, "bin", "mariadbd")
}

func ClientPath(prefix string) string {
	return firstExistingPath(
		filepath.Join(prefix, "bin", "mysql"),
		filepath.Join(prefix, "bin", "mariadb"),
	)
}

func DumpPath(prefix string) string {
	return firstExistingPath(
		filepath.Join(prefix, "bin", "mysqldump"),
		filepath.Join(prefix, "bin", "mariadb-dump"),
	)
}

func AdminPath(prefix string) string {
	return firstExistingPath(
		filepath.Join(prefix, "bin", "mariadb-admin"),
		filepath.Join(prefix, "bin", "mysqladmin"),
	)
}

func UpgradePath(prefix string) string {
	return firstExistingPath(
		filepath.Join(prefix, "bin", "mariadb-upgrade"),
		filepath.Join(prefix, "bin", "mysql_upgrade"),
	)
}

func InstallDBPath(prefix string) string {
	return firstExistingPath(
		filepath.Join(prefix, "scripts", "mariadb-install-db"),
		filepath.Join(prefix, "bin", "mariadb-install-db"),
		filepath.Join(prefix, "scripts", "mysql_install_db"),
		filepath.Join(prefix, "bin", "mysql_install_db"),
	)
}

func PluginDir(prefix string) string {
	return filepath.Join(prefix, "lib", "plugin")
}

func LibraryDir(prefix string) string {
	return filepath.Join(prefix, "lib")
}

func runBrew(ctx context.Context, brewPath string, args ...string) error {
	command := exec.CommandContext(ctx, brewPath, args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("brew %s failed: %s", strings.Join(args, " "), strings.TrimSpace(string(output)))
	}
	return nil
}

func installedVersion(ctx context.Context, brewPath, formula string) (bool, string, error) {
	command := exec.CommandContext(ctx, brewPath, "list", "--versions", formula)
	output, err := command.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			return false, "", nil
		}
		return false, "", fmt.Errorf("brew list --versions %s failed: %w", formula, err)
	}

	trimmed := strings.TrimSpace(string(output))
	if trimmed == "" {
		return false, "", nil
	}

	fields := strings.Fields(trimmed)
	if len(fields) < 2 {
		return true, "", nil
	}
	return true, fields[len(fields)-1], nil
}

func isPinned(ctx context.Context, brewPath, formula string) (bool, error) {
	command := exec.CommandContext(ctx, brewPath, "list", "--pinned")
	output, err := command.Output()
	if err != nil {
		return false, fmt.Errorf("brew list --pinned failed: %w", err)
	}

	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if strings.TrimSpace(line) == formula {
			return true, nil
		}
	}
	return false, nil
}

func prefix(ctx context.Context, brewPath, formula string) (string, error) {
	command := exec.CommandContext(ctx, brewPath, "--prefix", formula)
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("brew --prefix %s failed: %s", formula, strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}

func binaryVersion(binaryPath string) (string, error) {
	command := exec.Command(binaryPath, "--version")
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s --version failed: %s", binaryPath, strings.TrimSpace(string(output)))
	}

	match := versionPattern.FindStringSubmatch(string(output))
	if len(match) != 2 {
		return "", fmt.Errorf("could not parse MariaDB version from %s", strings.TrimSpace(string(output)))
	}
	return match[1], nil
}

func firstExistingPath(paths ...string) string {
	for _, candidate := range paths {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return paths[0]
}

func brewBinary() (string, error) {
	candidates := []string{
		strings.TrimSpace(os.Getenv("HOMEBREW_PREFIX")),
		"/opt/homebrew/bin",
		"/usr/local/bin",
	}

	if path, err := exec.LookPath("brew"); err == nil {
		return path, nil
	}

	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		brewPath := filepath.Join(candidate, "brew")
		if _, err := os.Stat(brewPath); err == nil {
			return brewPath, nil
		}
	}

	return "", exec.ErrNotFound
}
