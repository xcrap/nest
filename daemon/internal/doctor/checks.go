package doctor

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/xcrap/nest/daemon/internal/config"
	dbmeta "github.com/xcrap/nest/daemon/internal/mariadb"
	"github.com/xcrap/nest/daemon/internal/state"
	"github.com/xcrap/nest/internal/bootstrapstate"
)

type Service struct {
	paths    state.Paths
	store    *config.Store
	lookPath func(string) (string, error)
}

func NewService(paths state.Paths, store *config.Store) *Service {
	return &Service{
		paths:    paths,
		store:    store,
		lookPath: exec.LookPath,
	}
}

func (s *Service) Run() ([]config.DoctorCheck, error) {
	settings, err := s.store.LoadSettings()
	if err != nil {
		return nil, err
	}

	checks := []config.DoctorCheck{
		s.daemonSocketCheck(),
		s.phpSymlinkCheck(),
		s.shellPathCheck(settings),
		s.resolverCheck(),
		s.portsCheck(),
		s.localCACheck(),
		s.frankenphpCheck(),
		s.mariaDBInstallCheck(),
	}

	return checks, nil
}

func (s *Service) daemonSocketCheck() config.DoctorCheck {
	info, err := os.Stat(s.paths.SocketPath)
	if err != nil {
		return config.DoctorCheck{
			ID:      "daemon-socket",
			Status:  "warn",
			Message: "Nest daemon socket is missing.",
			FixHint: "Open the desktop app so Nest can start its background daemon.",
		}
	}

	if info.Mode().Perm() != 0o600 {
		return config.DoctorCheck{
			ID:      "daemon-socket",
			Status:  "warn",
			Message: "Nest daemon socket permissions are not user-only.",
			FixHint: "Restart Nest so it can recreate the socket with 0600 permissions.",
		}
	}

	return config.DoctorCheck{
		ID:      "daemon-socket",
		Status:  "pass",
		Message: "Nest daemon socket is local-only.",
	}
}

func (s *Service) phpSymlinkCheck() config.DoctorCheck {
	info, err := os.Lstat(s.paths.ActivePHPPath())
	if err != nil {
		return config.DoctorCheck{
			ID:      "php-symlink",
			Status:  "fail",
			Message: "Nest PHP symlink is missing.",
			FixHint: "Install and activate a PHP runtime with `nestcli php install <version>` and `nestcli php activate <version>`.",
		}
	}

	if info.Mode()&os.ModeSymlink == 0 {
		return config.DoctorCheck{
			ID:      "php-symlink",
			Status:  "fail",
			Message: "Nest PHP entrypoint is not a symlink.",
			FixHint: "Re-run `nestcli php activate 8.5` to restore the managed PHP symlink.",
		}
	}

	if _, err := os.Stat(s.paths.ActivePHPPath()); err != nil {
		return config.DoctorCheck{
			ID:      "php-symlink",
			Status:  "fail",
			Message: "Nest PHP symlink points to a missing runtime.",
			FixHint: "Re-run `nestcli php install 8.5` and `nestcli php activate 8.5`.",
		}
	}

	return config.DoctorCheck{
		ID:      "php-symlink",
		Status:  "pass",
		Message: "Nest PHP symlink is valid.",
	}
}

func (s *Service) shellPathCheck(settings config.Settings) config.DoctorCheck {
	rcPath := settings.ShellIntegration.RcFile
	if rcPath == "" {
		rcPath = filepath.Join(s.paths.HomeDir, ".zshrc")
	}
	content, err := os.ReadFile(rcPath)
	if err != nil {
		return config.DoctorCheck{
			ID:      "shell-path",
			Status:  "warn",
			Message: "zsh integration file could not be read.",
			FixHint: "Run `nestcli shell integrate --zsh` and restart your shell.",
		}
	}

	if !strings.Contains(string(content), s.paths.BinDir) {
		return config.DoctorCheck{
			ID:      "shell-path",
			Status:  "warn",
			Message: "zsh integration block does not point to Nest's bin directory.",
			FixHint: "Re-run `nestcli shell integrate --zsh` so Nest's bin path is exported in ~/.zshrc.",
		}
	}
	return config.DoctorCheck{
		ID:      "shell-path",
		Status:  "pass",
		Message: "Shell PATH includes Nest's managed bin directory.",
	}
}

func (s *Service) resolverCheck() config.DoctorCheck {
	if !bootstrapstate.ResolverConfigured() {
		return config.DoctorCheck{
			ID:      "test-resolver",
			Status:  "warn",
			Message: "Resolver file for `.test` is missing or points away from Nest.",
			FixHint: "Re-run `nestcli bootstrap test-domain` to recreate `/etc/resolver/test`.",
		}
	}
	return config.DoctorCheck{
		ID:      "test-resolver",
		Status:  "pass",
		Message: "`.test` DNS bootstrap is configured.",
	}
}

func (s *Service) portsCheck() config.DoctorCheck {
	if !bootstrapstate.PrivilegedPortsConfigured() {
		return config.DoctorCheck{
			ID:      "privileged-ports",
			Status:  "warn",
			Message: "PF redirect rules for 80/443 are missing or incomplete.",
			FixHint: "Run `nestcli bootstrap test-domain` so Nest can install PF redirects to 8080/8443.",
		}
	}
	return config.DoctorCheck{
		ID:      "privileged-ports",
		Status:  "pass",
		Message: "Privileged port forwarding files are configured.",
	}
}

func (s *Service) localCACheck() config.DoctorCheck {
	if !bootstrapstate.LocalCATrusted(s.paths.HomeDir) {
		return config.DoctorCheck{
			ID:      "local-ca",
			Status:  "warn",
			Message: "Nest's local HTTPS certificate authority is not trusted.",
			FixHint: "Run `sudo nestcli bootstrap trust-local-ca` or use the desktop app.",
		}
	}

	return config.DoctorCheck{
		ID:      "local-ca",
		Status:  "pass",
		Message: "Nest's local HTTPS certificate authority is trusted.",
	}
}

func (s *Service) frankenphpCheck() config.DoctorCheck {
	if _, err := os.Stat(s.paths.FrankenPHPPath()); err != nil {
		return config.DoctorCheck{
			ID:      "frankenphp-binary",
			Status:  "warn",
			Message: "FrankenPHP binary is not installed yet.",
			FixHint: "Run `nestcli php install 8.5` or `nestcli services start` to install the pinned FrankenPHP runtime.",
		}
	}
	return config.DoctorCheck{
		ID:      "frankenphp-binary",
		Status:  "pass",
		Message: "FrankenPHP binary is installed.",
	}
}

func (s *Service) mariaDBInstallCheck() config.DoctorCheck {
	runtime, err := dbmeta.Detect(context.Background())
	if err != nil {
		return config.DoctorCheck{
			ID:      "mariadb-runtime",
			Status:  "warn",
			Message: err.Error(),
			FixHint: "Install Homebrew and re-run MariaDB install from Nest.",
		}
	}

	if !runtime.Installed {
		return config.DoctorCheck{
			ID:      "mariadb-runtime",
			Status:  "warn",
			Message: "Homebrew MariaDB runtime is not installed.",
			FixHint: "Run `nestcli mariadb install` so Nest can install and pin " + runtime.Formula + ".",
		}
	}

	if !runtime.Pinned {
		return config.DoctorCheck{
			ID:      "mariadb-runtime",
			Status:  "warn",
			Message: "Homebrew MariaDB formula is installed but not pinned.",
			FixHint: "Run `nestcli mariadb install` so Nest can pin " + runtime.Formula + ".",
		}
	}

	return config.DoctorCheck{
		ID:      "mariadb-runtime",
		Status:  "pass",
		Message: "Homebrew MariaDB runtime is installed and pinned.",
	}
}

func (s *Service) WithLookPath(lookup func(string) (string, error)) *Service {
	s.lookPath = lookup
	return s
}

var ErrDaemonNotRunning = errors.New("nest daemon is not running")
