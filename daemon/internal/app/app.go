package app

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/xcrap/nest/daemon/internal/composer"
	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/dns"
	"github.com/xcrap/nest/daemon/internal/doctor"
	"github.com/xcrap/nest/daemon/internal/runtime"
	"github.com/xcrap/nest/daemon/internal/services"
	"github.com/xcrap/nest/daemon/internal/shell"
	"github.com/xcrap/nest/daemon/internal/sites"
	"github.com/xcrap/nest/daemon/internal/state"
	"github.com/xcrap/nest/internal/bootstrapstate"
)

type App struct {
	Paths      state.Paths
	Store      *config.Store
	Sites      *sites.Service
	Runtime    *runtime.Manager
	FrankenPHP *services.FrankenPHPService
	MariaDB    *services.MariaDBService
	Doctor     *doctor.Service
	DNS        *dns.Server
}

func New() (*App, error) {
	paths, err := state.DefaultPaths()
	if err != nil {
		return nil, err
	}

	store := config.NewStore(paths)
	application := &App{
		Paths:      paths,
		Store:      store,
		Sites:      sites.NewService(paths, store),
		Runtime:    runtime.NewManager(paths, store),
		FrankenPHP: services.NewFrankenPHPService(paths),
		MariaDB:    services.NewMariaDBService(paths),
		Doctor:     doctor.NewService(paths, store),
		DNS:        dns.NewServer("127.0.0.1:5354"),
	}

	return application, nil
}

func (a *App) Bootstrap() error {
	if err := a.Store.Ensure(); err != nil {
		return err
	}
	if err := a.ensureComposerWrapper(); err != nil {
		return err
	}
	if err := a.ensureNestcliSymlink(); err != nil {
		return err
	}
	if err := a.ensureShellIntegration(); err != nil {
		return err
	}
	return a.Sites.RewriteCaddyfile()
}

func (a *App) StartDNS(ctx context.Context) error {
	return a.DNS.Start(ctx)
}

func (a *App) BootstrapTestDomain(ctx context.Context) error {
	helperPath, err := resolveHelperBinary()
	if err != nil {
		return err
	}

	command := exec.CommandContext(ctx, helperPath, "bootstrap", "test-domain")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, bytes.TrimSpace(output))
	}

	return a.MarkTestDomainBootstrapped()
}

func (a *App) MarkTestDomainBootstrapped() error {
	return a.syncBootstrapState(true)
}

func (a *App) TrustLocalCA(ctx context.Context) error {
	_ = ctx
	if err := bootstrapstate.TrustLocalCA(a.Paths.HomeDir); err != nil {
		return err
	}

	return a.MarkLocalCATrusted()
}

func (a *App) MarkLocalCATrusted() error {
	return a.syncBootstrapState(true)
}

func (a *App) RefreshBootstrapState() error {
	return a.syncBootstrapState(false)
}

func (a *App) UnbootstrapTestDomain(ctx context.Context) error {
	helperPath, err := resolveHelperBinary()
	if err != nil {
		return err
	}

	command := exec.CommandContext(ctx, helperPath, "unbootstrap", "test-domain")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, bytes.TrimSpace(output))
	}

	return a.syncBootstrapState(false)
}

func (a *App) UntrustLocalCA(ctx context.Context) error {
	_ = ctx
	if err := bootstrapstate.UntrustLocalCA(a.Paths.HomeDir); err != nil {
		return err
	}

	return a.syncBootstrapState(false)
}

func (a *App) ResolvedSettings() (config.Settings, error) {
	settings, err := a.Store.LoadSettings()
	if err != nil {
		return config.Settings{}, err
	}
	updated, changed := a.bootstrapState(settings)
	if !changed {
		return updated, nil
	}
	if err := a.Store.SaveSettings(updated); err != nil {
		return config.Settings{}, err
	}
	return updated, nil
}

func (a *App) FixPHPSymlink(ctx context.Context) error {
	if err := a.Runtime.Install(ctx, "8.5"); err != nil {
		return err
	}
	return a.Runtime.Activate("8.5")
}

func (a *App) FixShellPath() error {
	rcPath, err := shell.ResolveZshRC()
	if err != nil {
		return err
	}
	state, err := shell.EnsureZshIntegration(rcPath, a.Paths.BinDir)
	if err != nil {
		return err
	}
	settings, err := a.Store.LoadSettings()
	if err != nil {
		return err
	}
	settings.ShellIntegration = state
	return a.Store.SaveSettings(settings)
}

func (a *App) ComposerRuntime(ctx context.Context) (config.ComposerRuntime, error) {
	return composer.Detect(ctx, a.Paths)
}

func (a *App) CheckComposerUpdates(ctx context.Context) (config.ComposerRuntime, error) {
	return composer.CheckForUpdates(ctx, a.Paths)
}

func (a *App) InstallComposer(ctx context.Context) (config.ComposerRuntime, error) {
	runtime, err := composer.Install(ctx, a.Paths)
	if err != nil {
		return runtime, err
	}
	if err := a.ensureComposerWrapper(); err != nil {
		return config.ComposerRuntime{}, err
	}
	detected, err := composer.Detect(ctx, a.Paths)
	if err != nil {
		return detected, err
	}
	detected.LatestVersion = runtime.LatestVersion
	detected.LatestChecksum = runtime.LatestChecksum
	detected.UpdateAvailable = false
	return detected, nil
}

func (a *App) RollbackComposer(ctx context.Context) (config.ComposerRuntime, error) {
	runtime, err := composer.Rollback(ctx, a.Paths)
	if err != nil {
		return runtime, err
	}
	if err := a.ensureComposerWrapper(); err != nil {
		return config.ComposerRuntime{}, err
	}
	return composer.Detect(ctx, a.Paths)
}

func (a *App) FixComposerRuntime(ctx context.Context) error {
	if _, err := os.Stat(a.Paths.ActivePHPPath()); err != nil {
		if err := a.FixPHPSymlink(ctx); err != nil {
			return err
		}
	}
	_, err := a.InstallComposer(ctx)
	return err
}

func (a *App) ensureShellIntegration() error {
	rcPath, err := shell.ResolveZshRC()
	if err != nil {
		return err
	}
	state, err := shell.EnsureZshIntegration(rcPath, a.Paths.BinDir)
	if err != nil {
		return err
	}
	settings, err := a.Store.LoadSettings()
	if err != nil {
		return err
	}
	settings.ShellIntegration = state
	return a.Store.SaveSettings(settings)
}

func (a *App) ensureNestcliSymlink() error {
	nestcliDst := filepath.Join(a.Paths.BinDir, "nestcli")

	// Find the nestcli binary next to the running executable
	executable, err := os.Executable()
	if err != nil {
		return nil
	}
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		resolved = executable
	}
	candidate := filepath.Join(filepath.Dir(resolved), "nestcli")
	if _, err := os.Stat(candidate); err != nil {
		return nil
	}
	if samePath(candidate, nestcliDst) {
		return nil
	}
	if existingTarget, err := os.Readlink(nestcliDst); err == nil {
		if samePath(existingTarget, candidate) {
			return nil
		}
	}

	_ = os.Remove(nestcliDst)
	return os.Symlink(candidate, nestcliDst)
}

func (a *App) ensureComposerWrapper() error {
	if _, err := os.Stat(a.Paths.ComposerPharPath); err != nil {
		if os.IsNotExist(err) {
			_ = os.Remove(a.Paths.ComposerWrapperPath)
			return nil
		}
		return err
	}

	content := "#!/usr/bin/env bash\n" +
		"set -euo pipefail\n" +
		"PHP_BIN=\"$(cd \"$(dirname \"$0\")\" && pwd)/php\"\n" +
		"COMPOSER_PHAR=\"" + a.Paths.ComposerPharPath + "\"\n" +
		"if [[ ! -f \"$COMPOSER_PHAR\" ]]; then\n" +
		"  echo \"composer.phar not found at $COMPOSER_PHAR\" >&2\n" +
		"  exit 1\n" +
		"fi\n" +
		"exec \"$PHP_BIN\" \"$COMPOSER_PHAR\" \"$@\"\n"
	return os.WriteFile(a.Paths.ComposerWrapperPath, []byte(content), 0o755)
}

func resolveHelperBinary() (string, error) {
	return ResolveHelperBinaryForCLI()
}

func ResolveHelperBinaryForCLI() (string, error) {
	if helper := os.Getenv("NEST_HELPER_BIN"); helper != "" {
		return helper, nil
	}

	workingDir, err := os.Getwd()
	if err == nil {
		candidate := filepath.Join(workingDir, "bin", "nesthelper")
		if _, statErr := os.Stat(candidate); statErr == nil {
			return candidate, nil
		}
	}

	executable, err := os.Executable()
	if err == nil {
		candidate := filepath.Join(filepath.Dir(executable), "nesthelper")
		if _, statErr := os.Stat(candidate); statErr == nil {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("nesthelper binary was not found; build it into ./bin/nesthelper or set NEST_HELPER_BIN")
}

func samePath(left, right string) bool {
	leftResolved, leftErr := filepath.EvalSymlinks(left)
	if leftErr != nil {
		leftResolved = left
	}
	rightResolved, rightErr := filepath.EvalSymlinks(right)
	if rightErr != nil {
		rightResolved = right
	}
	return filepath.Clean(leftResolved) == filepath.Clean(rightResolved)
}

func (a *App) syncBootstrapState(markCompletion bool) error {
	settings, err := a.Store.LoadSettings()
	if err != nil {
		return err
	}

	updated, changed := a.bootstrapState(settings)
	if markCompletion && (updated.Bootstrap.TestDomainConfigured || updated.Bootstrap.LocalCATrusted) {
		updated.Bootstrap.LastBootstrapCompleted = time.Now().UTC()
		changed = true
	}
	if !changed {
		return nil
	}
	return a.Store.SaveSettings(updated)
}

func (a *App) bootstrapState(settings config.Settings) (config.Settings, bool) {
	updated := settings
	changed := false

	if updated.Bootstrap.ResolverIPAddress != bootstrapstate.ResolverIP {
		updated.Bootstrap.ResolverIPAddress = bootstrapstate.ResolverIP
		changed = true
	}
	if updated.Bootstrap.ResolverPort != 5354 {
		updated.Bootstrap.ResolverPort = 5354
		changed = true
	}

	testDomainConfigured := bootstrapstate.ResolverConfigured()
	if updated.Bootstrap.TestDomainConfigured != testDomainConfigured {
		updated.Bootstrap.TestDomainConfigured = testDomainConfigured
		changed = true
	}

	privilegedPortsReady := bootstrapstate.PrivilegedPortsConfigured()
	if updated.Bootstrap.PrivilegedPortsReady != privilegedPortsReady {
		updated.Bootstrap.PrivilegedPortsReady = privilegedPortsReady
		changed = true
	}

	localCATrusted := bootstrapstate.LocalCATrusted(a.Paths.HomeDir)
	if updated.Bootstrap.LocalCATrusted != localCATrusted {
		updated.Bootstrap.LocalCATrusted = localCATrusted
		changed = true
	}

	return updated, changed
}
