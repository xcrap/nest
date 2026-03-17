package doctor

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/xcrap/nest/daemon/internal/composer"
	"github.com/xcrap/nest/daemon/internal/config"
	dbmeta "github.com/xcrap/nest/daemon/internal/mariadb"
	"github.com/xcrap/nest/daemon/internal/services"
	"github.com/xcrap/nest/daemon/internal/state"
	"github.com/xcrap/nest/internal/bootstrapstate"
)

const launchAgentLabel = "dev.nest.nestd"

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

	builders := []func() config.DoctorCheck{
		s.daemonSocketCheck,
		s.launchAgentCheck,
		s.phpSymlinkCheck,
		func() config.DoctorCheck { return s.shellPathCheck(settings) },
		s.resolverCheck,
		s.portsCheck,
		s.httpsLocalhostCheck,
		s.localCACheck,
		s.frankenphpCheck,
		s.frankenphpAdminCheck,
		s.composerCheck,
		s.mariaDBInstallCheck,
		s.mariaDBReadyCheck,
	}

	checks := make([]config.DoctorCheck, len(builders))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(builders))
	for index, build := range builders {
		go func(index int, build func() config.DoctorCheck) {
			defer waitGroup.Done()
			checks[index] = build()
		}(index, build)
	}
	waitGroup.Wait()

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

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := pingDaemonSocket(ctx, s.paths.SocketPath); err != nil {
		return config.DoctorCheck{
			ID:      "daemon-socket",
			Status:  "warn",
			Message: "Nest daemon socket exists but the daemon did not answer a health probe.",
			FixHint: "Open Nest.app or restart the `dev.nest.nestd` launch agent.",
		}
	}

	return config.DoctorCheck{
		ID:      "daemon-socket",
		Status:  "pass",
		Message: "Nest daemon socket is reachable and local-only.",
	}
}

func (s *Service) launchAgentCheck() config.DoctorCheck {
	output, err := exec.Command("launchctl", "print", fmt.Sprintf("gui/%d/%s", os.Getuid(), launchAgentLabel)).CombinedOutput()
	if err != nil || !launchAgentHealthy(string(output)) {
		return config.DoctorCheck{
			ID:      "launch-agent",
			Status:  "warn",
			Message: "Nest launch agent is not loaded and healthy.",
			FixHint: "Open Nest.app so it can install and start the `dev.nest.nestd` launch agent.",
		}
	}

	return config.DoctorCheck{
		ID:      "launch-agent",
		Status:  "pass",
		Message: "Nest launch agent is loaded and running.",
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

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, "nest-doctor.test")
	if err != nil || !containsLoopbackAddress(addresses) {
		return config.DoctorCheck{
			ID:      "test-resolver",
			Status:  "warn",
			Message: "`.test` is configured but does not resolve to loopback right now.",
			FixHint: "Re-run `nestcli bootstrap test-domain` and make sure the Nest daemon is running so DNS answers on 127.0.0.1:5354.",
		}
	}
	return config.DoctorCheck{
		ID:      "test-resolver",
		Status:  "pass",
		Message: "`.test` domains resolve to loopback through the system resolver.",
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

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	statusCode, location, _, err := requestURL(ctx, "http://localhost", false)
	if err != nil {
		return config.DoctorCheck{
			ID:      "privileged-ports",
			Status:  "warn",
			Message: "PF redirect rules are installed but http://localhost did not reach Nest.",
			FixHint: "Make sure FrankenPHP is running and re-run `nestcli bootstrap test-domain` if port forwarding is broken.",
		}
	}
	if !validLocalHTTPRoute(statusCode, location) {
		return config.DoctorCheck{
			ID:      "privileged-ports",
			Status:  "warn",
			Message: fmt.Sprintf("http://localhost returned an unexpected response (%d).", statusCode),
			FixHint: "Port 80 should redirect to https://localhost through Nest. Check for competing local services or restart Nest services.",
		}
	}
	return config.DoctorCheck{
		ID:      "privileged-ports",
		Status:  "pass",
		Message: "Local port 80 forwarding reaches Nest and redirects to HTTPS.",
	}
}

func (s *Service) httpsLocalhostCheck() config.DoctorCheck {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	statusCode, _, _, err := requestURL(ctx, "https://localhost", true)
	if err != nil {
		return config.DoctorCheck{
			ID:      "https-localhost",
			Status:  "warn",
			Message: "https://localhost is not trusted or not responding.",
			FixHint: "Trust the local CA in Settings and make sure FrankenPHP is running before retrying HTTPS.",
		}
	}
	if statusCode != http.StatusNoContent {
		return config.DoctorCheck{
			ID:      "https-localhost",
			Status:  "warn",
			Message: fmt.Sprintf("https://localhost returned an unexpected status (%d).", statusCode),
			FixHint: "Nest expects the managed localhost endpoint to answer with 204 over trusted HTTPS.",
		}
	}
	return config.DoctorCheck{
		ID:      "https-localhost",
		Status:  "pass",
		Message: "https://localhost is trusted and responding through Nest.",
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

func (s *Service) frankenphpAdminCheck() config.DoctorCheck {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	statusCode, _, body, err := requestURL(ctx, "http://127.0.0.1:2019/config/", true)
	if err != nil {
		return config.DoctorCheck{
			ID:      "frankenphp-admin",
			Status:  "warn",
			Message: "FrankenPHP admin endpoint is not responding on 127.0.0.1:2019.",
			FixHint: "Start Nest services so FrankenPHP can expose the admin API.",
		}
	}
	if statusCode != http.StatusOK || !healthyAdminConfig(body) {
		return config.DoctorCheck{
			ID:      "frankenphp-admin",
			Status:  "warn",
			Message: "FrankenPHP admin endpoint responded, but the config did not look like Nest.",
			FixHint: "Restart Nest services so FrankenPHP can reload the managed Caddy configuration.",
		}
	}
	return config.DoctorCheck{
		ID:      "frankenphp-admin",
		Status:  "pass",
		Message: "FrankenPHP admin API is responding with the managed config.",
	}
}

func (s *Service) composerCheck() config.DoctorCheck {
	runtime, err := composer.Detect(context.Background(), s.paths)
	if err != nil {
		return config.DoctorCheck{
			ID:      "composer-runtime",
			Status:  "warn",
			Message: "Composer runtime could not be inspected.",
			FixHint: "Run `nestcli composer install` to reinstall Composer.",
		}
	}

	if !runtime.Installed {
		return config.DoctorCheck{
			ID:      "composer-runtime",
			Status:  "warn",
			Message: "Composer is not installed.",
			FixHint: "Run `nestcli composer install` so Nest can install the official Composer phar and wrapper.",
		}
	}

	if !runtime.WrapperPresent {
		return config.DoctorCheck{
			ID:      "composer-runtime",
			Status:  "warn",
			Message: "Composer phar exists but the Nest wrapper is missing.",
			FixHint: "Run `nestcli composer install` so Nest can restore the managed composer wrapper.",
		}
	}

	if runtime.LastError != "" {
		return config.DoctorCheck{
			ID:      "composer-runtime",
			Status:  "warn",
			Message: "Composer is installed but could not be validated.",
			FixHint: runtime.LastError,
		}
	}

	return config.DoctorCheck{
		ID:      "composer-runtime",
		Status:  "pass",
		Message: "Composer runtime is installed and managed by Nest.",
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

func (s *Service) mariaDBReadyCheck() config.DoctorCheck {
	runtimeCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	runtime, err := dbmeta.Detect(runtimeCtx)
	if err != nil {
		return config.DoctorCheck{
			ID:      "mariadb-ready",
			Status:  "warn",
			Message: "MariaDB readiness could not be checked.",
			FixHint: "Run `nestcli mariadb install` and `nestcli mariadb start`, then retry Doctor.",
		}
	}
	if !runtime.Installed {
		return config.DoctorCheck{
			ID:      "mariadb-ready",
			Status:  "warn",
			Message: "MariaDB is not installed, so readiness could not be checked.",
			FixHint: "Run `nestcli mariadb install` if your project needs MariaDB.",
		}
	}

	service := services.NewMariaDBService(s.paths)
	readyCtx, readyCancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer readyCancel()
	if err := service.ReadyWithRuntime(readyCtx, runtime); err != nil {
		return config.DoctorCheck{
			ID:      "mariadb-ready",
			Status:  "warn",
			Message: "MariaDB is not answering a ping right now.",
			FixHint: "Start MariaDB from Nest and make sure the managed socket at " + s.paths.MariaDBSocketPath + " is healthy.",
		}
	}

	return config.DoctorCheck{
		ID:      "mariadb-ready",
		Status:  "pass",
		Message: "MariaDB is answering a local readiness ping.",
	}
}

func (s *Service) WithLookPath(lookup func(string) (string, error)) *Service {
	s.lookPath = lookup
	return s
}

var ErrDaemonNotRunning = errors.New("nest daemon is not running")

func pingDaemonSocket(ctx context.Context, socketPath string) error {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, "unix", socketPath)
		},
	}
	client := &http.Client{Transport: transport}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://nest/meta", nil)
	if err != nil {
		return err
	}

	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("daemon health probe returned %d", response.StatusCode)
	}
	return nil
}

func requestURL(ctx context.Context, rawURL string, allowRedirects bool) (int, string, string, error) {
	client := &http.Client{
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if allowRedirects {
				return nil
			}
			return http.ErrUseLastResponse
		},
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return 0, "", "", err
	}

	response, err := client.Do(request)
	if err != nil {
		return 0, "", "", err
	}
	defer response.Body.Close()

	body, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil {
		return 0, "", "", err
	}
	return response.StatusCode, response.Header.Get("Location"), string(body), nil
}

func launchAgentHealthy(output string) bool {
	return strings.Contains(output, "type = LaunchAgent") && strings.Contains(output, "state = running")
}

func containsLoopbackAddress(addresses []net.IPAddr) bool {
	for _, address := range addresses {
		if address.IP.IsLoopback() {
			return true
		}
	}
	return false
}

func validLocalHTTPRoute(statusCode int, location string) bool {
	if statusCode == http.StatusNoContent {
		return true
	}

	switch statusCode {
	case http.StatusMovedPermanently, http.StatusFound, http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
	default:
		return false
	}

	return strings.HasPrefix(location, "https://localhost")
}

func healthyAdminConfig(body string) bool {
	return strings.Contains(body, `"listen":"localhost:2019"`) &&
		strings.Contains(body, `"http_port":8080`) &&
		strings.Contains(body, `"https_port":8443`)
}
