package doctor

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/state"
)

type Service struct {
	paths          state.Paths
	store          *config.Store
	lookPath       func(string) (string, error)
	processRunning func(string) bool
}

func NewService(paths state.Paths, store *config.Store) *Service {
	return &Service{
		paths:          paths,
		store:          store,
		lookPath:       exec.LookPath,
		processRunning: defaultProcessRunning,
	}
}

func (s *Service) Run() ([]config.DoctorCheck, error) {
	settings, err := s.store.LoadSettings()
	if err != nil {
		return nil, err
	}

	checks := []config.DoctorCheck{
		s.phpSymlinkCheck(),
		s.shellPathCheck(settings),
		s.resolverCheck(settings),
		s.portsCheck(settings),
		s.frankenphpCheck(),
		s.herdCheck(),
	}

	return checks, nil
}

func (s *Service) phpSymlinkCheck() config.DoctorCheck {
	if _, err := os.Stat(s.paths.ActivePHPPath()); err != nil {
		return config.DoctorCheck{
			ID:      "php-symlink",
			Status:  "fail",
			Message: "Nest PHP symlink is missing.",
			FixHint: "Install and activate a PHP runtime with `nestctl php install <version>` and `nestctl php activate <version>`.",
		}
	}
	return config.DoctorCheck{
		ID:      "php-symlink",
		Status:  "pass",
		Message: "Nest PHP symlink exists.",
		FixHint: "",
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
			FixHint: "Run `nestctl shell integrate --zsh` and restart your shell.",
		}
	}

	if !strings.Contains(string(content), s.paths.BinDir) {
		return config.DoctorCheck{
			ID:      "shell-path",
			Status:  "warn",
			Message: "zsh integration block does not point to Nest's bin directory.",
			FixHint: "Re-run `nestctl shell integrate --zsh` so Nest's bin path is exported in ~/.zshrc.",
		}
	}
	return config.DoctorCheck{
		ID:      "shell-path",
		Status:  "pass",
		Message: "Shell PATH resolves to Nest's managed PHP binary.",
		FixHint: "",
	}
}

func (s *Service) resolverCheck(_ config.Settings) config.DoctorCheck {
	data, err := os.ReadFile("/etc/resolver/test")
	if err != nil {
		return config.DoctorCheck{
			ID:      "test-resolver",
			Status:  "warn",
			Message: "Resolver file for `.test` is missing.",
			FixHint: "Re-run `nestctl bootstrap test-domain` to recreate `/etc/resolver/test`.",
		}
	}
	if !strings.Contains(string(data), "127.0.0.1") || !strings.Contains(string(data), "5354") {
		return config.DoctorCheck{
			ID:      "test-resolver",
			Status:  "warn",
			Message: "Resolver file for `.test` does not point to Nest's local DNS server.",
			FixHint: "Re-run `nestctl bootstrap test-domain` so the resolver points to 127.0.0.1:5354.",
		}
	}
	return config.DoctorCheck{
		ID:      "test-resolver",
		Status:  "pass",
		Message: "`.test` DNS bootstrap is configured.",
		FixHint: "",
	}
}

func (s *Service) portsCheck(_ config.Settings) config.DoctorCheck {
	pfConf, err := os.ReadFile("/etc/pf.conf")
	if err != nil {
		return config.DoctorCheck{
			ID:      "privileged-ports",
			Status:  "warn",
			Message: "PF configuration could not be read.",
			FixHint: "Re-run `nestctl bootstrap test-domain` so Nest can configure local port forwarding.",
		}
	}
	anchor, err := os.ReadFile("/etc/pf.anchors/dev.xcrap.nest")
	if err != nil {
		return config.DoctorCheck{
			ID:      "privileged-ports",
			Status:  "warn",
			Message: "Nest PF anchor file is missing.",
			FixHint: "Re-run `nestctl bootstrap test-domain` so Nest can install PF redirects to 8080/8443.",
		}
	}
	if !strings.Contains(string(pfConf), `rdr-anchor "dev.xcrap.nest"`) || !strings.Contains(string(anchor), "port 8080") {
		return config.DoctorCheck{
			ID:      "privileged-ports",
			Status:  "warn",
			Message: "Privileged port forwarding for 80/443 is not configured correctly.",
			FixHint: "Run `nestctl bootstrap test-domain` so Nest can install PF redirects to 8080/8443.",
		}
	}
	return config.DoctorCheck{
		ID:      "privileged-ports",
		Status:  "pass",
		Message: "Privileged port forwarding is configured.",
		FixHint: "",
	}
}

func (s *Service) frankenphpCheck() config.DoctorCheck {
	if _, err := os.Stat(s.paths.FrankenPHPPath()); err != nil {
		return config.DoctorCheck{
			ID:      "frankenphp-binary",
			Status:  "warn",
			Message: "FrankenPHP binary is not installed yet.",
			FixHint: "Run `nestctl php install 8.5` or `nestctl services start` to install the pinned FrankenPHP runtime.",
		}
	}
	return config.DoctorCheck{
		ID:      "frankenphp-binary",
		Status:  "pass",
		Message: "FrankenPHP binary is installed.",
		FixHint: "",
	}
}

func (s *Service) herdCheck() config.DoctorCheck {
	if s.processRunning("Herd") || s.processRunning("herd") {
		return config.DoctorCheck{
			ID:      "herd-conflict",
			Status:  "warn",
			Message: "Herd appears to be running and may conflict with Nest.",
			FixHint: "Quit Herd completely before starting Nest-managed sites.",
		}
	}
	return config.DoctorCheck{
		ID:      "herd-conflict",
		Status:  "pass",
		Message: "No running Herd process was detected.",
		FixHint: "",
	}
}

func defaultProcessRunning(name string) bool {
	command := exec.Command("pgrep", "-x", name)
	if err := command.Run(); err != nil {
		return false
	}
	return true
}

func (s *Service) WithProcessRunning(checker func(string) bool) *Service {
	s.processRunning = checker
	return s
}

func (s *Service) WithLookPath(lookup func(string) (string, error)) *Service {
	s.lookPath = lookup
	return s
}

var ErrDaemonNotRunning = errors.New("nest daemon is not running")
