package services

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/xcrap/nest/daemon/internal/config"
	dbmeta "github.com/xcrap/nest/daemon/internal/mariadb"
	"github.com/xcrap/nest/daemon/internal/state"
)

const mariaDBPort = 3306

type MariaDBService struct {
	paths state.Paths
	mu    sync.Mutex
	task  mariaDBTaskState
}

type mariaDBTaskState struct {
	Busy    bool
	Action  string
	Message string
	Error   string
}

func NewMariaDBService(paths state.Paths) *MariaDBService {
	return &MariaDBService{paths: paths}
}

func (s *MariaDBService) snapshotTask() mariaDBTaskState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.task
}

func (s *MariaDBService) beginTask(action, message string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.task.Busy {
		return fmt.Errorf("mariadb %s is already in progress", s.task.Action)
	}
	s.task = mariaDBTaskState{
		Busy:    true,
		Action:  action,
		Message: message,
	}
	return nil
}

func (s *MariaDBService) updateTask(message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.task.Busy {
		return
	}
	s.task.Message = message
}

func (s *MariaDBService) finishTask(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		s.task.Error = err.Error()
	}
	s.task.Busy = false
	s.task.Action = ""
	s.task.Message = ""
}

func (s *MariaDBService) InstallAsync() error {
	if err := s.beginTask("install", "Preparing Homebrew MariaDB runtime"); err != nil {
		return err
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
		defer cancel()
		err := s.install(ctx, s.updateTask)
		s.finishTask(err)
	}()

	return nil
}

func (s *MariaDBService) StartAsync() error {
	if err := s.beginTask("start", "Starting MariaDB"); err != nil {
		return err
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		err := s.start(ctx, s.updateTask)
		s.finishTask(err)
	}()

	return nil
}

func (s *MariaDBService) RuntimeStatus(ctx context.Context) (config.MariaDBRuntime, error) {
	runtime, err := dbmeta.Detect(ctx)
	if err != nil {
		task := s.snapshotTask()
		return config.MariaDBRuntime{
			Status:           "unknown",
			Formula:          dbmeta.Formula(),
			DataDir:          s.paths.MariaDBDataDir,
			SocketPath:       s.paths.MariaDBSocketPath,
			Port:             mariaDBPort,
			RootUser:         "root",
			PasswordlessRoot: true,
			Busy:             task.Busy,
			Activity:         task.Action,
			ActivityMessage:  task.Message,
			LastError:        firstNonEmpty(task.Error, err.Error()),
		}, nil
	}
	return s.runtimeStatusForRuntime(runtime), nil
}

func (s *MariaDBService) CheckForUpdates(ctx context.Context) (config.MariaDBRuntime, error) {
	return s.RuntimeStatus(ctx)
}

func (s *MariaDBService) Install(ctx context.Context) error {
	return s.install(ctx, nil)
}

func (s *MariaDBService) install(ctx context.Context, progress func(string)) error {
	runtime, err := dbmeta.EnsureInstalled(ctx, progress)
	if err != nil {
		return err
	}
	if progress != nil {
		progress("Refreshing Nest MariaDB wrappers")
	}
	return s.syncClientSymlinks(runtime.Prefix)
}

func (s *MariaDBService) Start(ctx context.Context) error {
	return s.start(ctx, nil)
}

func (s *MariaDBService) start(ctx context.Context, progress func(string)) error {
	if status, _ := s.Status(); status == "running" {
		return nil
	}

	runtime, err := dbmeta.EnsureInstalled(ctx, progress)
	if err != nil {
		return err
	}
	if !runtime.Installed || runtime.Prefix == "" {
		return fmt.Errorf("homebrew formula %s is not installed", runtime.Formula)
	}

	if progress != nil {
		progress("Refreshing Nest MariaDB wrappers")
	}
	if err := s.syncClientSymlinks(runtime.Prefix); err != nil {
		return err
	}

	if progress != nil {
		progress("Writing MariaDB configuration")
	}
	if err := s.writeConfig(runtime.Prefix); err != nil {
		return err
	}

	if progress != nil {
		progress("Initializing MariaDB data directory")
	}
	if err := s.ensureInitialized(ctx, runtime.Prefix); err != nil {
		return err
	}

	if progress != nil {
		progress("Rotating MariaDB logs")
	}
	if err := rotateLogFile(s.paths.MariaDBLogPath, 10<<20); err != nil {
		return err
	}

	logFile, err := os.OpenFile(s.paths.MariaDBLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}

	command := exec.Command(dbmeta.ServerPath(runtime.Prefix), "--defaults-file="+s.paths.MariaDBConfigPath)
	command.Env = s.commandEnv(runtime.Prefix)
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return err
	}

	if err := os.WriteFile(s.paths.MariaDBPIDPath, []byte(strconv.Itoa(command.Process.Pid)), 0o600); err != nil {
		_ = command.Process.Kill()
		_ = logFile.Close()
		return err
	}

	go func() {
		_ = command.Wait()
		_ = logFile.Close()
	}()

	readyCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if progress != nil {
		progress("Waiting for MariaDB to accept connections")
	}
	if err := s.waitUntilReady(readyCtx, runtime.Prefix); err != nil {
		_ = command.Process.Kill()
		_ = os.Remove(s.paths.MariaDBPIDPath)
		return err
	}

	if progress != nil {
		progress("Running MariaDB upgrade checks")
	}
	if err := s.runUpgrade(readyCtx, runtime.Prefix); err != nil {
		_ = s.Stop()
		return err
	}

	if progress != nil {
		progress("Configuring root access")
	}
	if err := s.ensurePasswordlessRoot(readyCtx, runtime.Prefix); err != nil {
		_ = s.Stop()
		return err
	}

	return nil
}

func (s *MariaDBService) Stop() error {
	process, err := s.processFromPIDFile()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}

	if err := process.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}

	if !waitForExit(process.Pid, 10*time.Second) {
		_ = process.Signal(syscall.SIGKILL)
		_ = waitForExit(process.Pid, 2*time.Second)
	}

	_ = os.Remove(s.paths.MariaDBPIDPath)
	_ = os.Remove(s.paths.MariaDBSocketPath)
	return nil
}

func (s *MariaDBService) Status() (string, error) {
	process, err := s.processFromPIDFile()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "stopped", nil
		}
		return "unknown", err
	}
	if err := process.Signal(syscall.Signal(0)); err != nil {
		_ = os.Remove(s.paths.MariaDBPIDPath)
		return "stopped", nil
	}
	return "running", nil
}

func (s *MariaDBService) runtimeStatusForRuntime(runtime dbmeta.Runtime) config.MariaDBRuntime {
	status, err := s.Status()
	if err != nil {
		status = "unknown"
	}
	task := s.snapshotTask()
	binaryPath := ""
	if runtime.Prefix != "" {
		binaryPath = dbmeta.ServerPath(runtime.Prefix)
	}

	return config.MariaDBRuntime{
		Installed:        runtime.Installed,
		Status:           status,
		InstalledVersion: runtime.InstalledVersion,
		Formula:          runtime.Formula,
		Pinned:           runtime.Pinned,
		Prefix:           runtime.Prefix,
		BinaryPath:       binaryPath,
		DataDir:          s.paths.MariaDBDataDir,
		SocketPath:       s.paths.MariaDBSocketPath,
		Port:             mariaDBPort,
		RootUser:         "root",
		PasswordlessRoot: true,
		Busy:             task.Busy,
		Activity:         task.Action,
		ActivityMessage:  task.Message,
		LastError:        task.Error,
	}
}

func (s *MariaDBService) syncClientSymlinks(prefix string) error {
	wrappers := map[string]string{
		s.paths.MySQLSymlinkPath():        dbmeta.ClientPath(prefix),
		s.paths.MySQLDumpSymlinkPath():    dbmeta.DumpPath(prefix),
		s.paths.MariaDBSymlinkPath():      dbmeta.ClientPath(prefix),
		s.paths.MariaDBAdminSymlinkPath(): dbmeta.AdminPath(prefix),
	}

	for wrapperPath, target := range wrappers {
		if err := writeMariaDBClientWrapper(wrapperPath, target, s.paths.MariaDBSocketPath); err != nil {
			return err
		}
	}

	return nil
}

func writeMariaDBClientWrapper(wrapperPath, target, socketPath string) error {
	content := "#!/usr/bin/env bash\n" +
		"set -euo pipefail\n" +
		"export MYSQL_UNIX_PORT=" + shellQuote(targetPathValue(socketPath)) + "\n" +
		"exec " + shellQuote(targetPathValue(target)) + " \"$@\"\n"

	if err := os.RemoveAll(wrapperPath); err != nil {
		return err
	}
	return os.WriteFile(wrapperPath, []byte(content), 0o755)
}

func targetPathValue(value string) string {
	return strings.ReplaceAll(value, "\n", "")
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

func (s *MariaDBService) ensureInitialized(ctx context.Context, prefix string) error {
	if _, err := os.Stat(filepath.Join(s.paths.MariaDBDataDir, "mysql", "db.opt")); err == nil {
		return nil
	}

	if err := os.MkdirAll(s.paths.MariaDBDataDir, 0o700); err != nil {
		return err
	}

	command := exec.CommandContext(
		ctx,
		dbmeta.InstallDBPath(prefix),
		"--no-defaults",
		"--datadir="+s.paths.MariaDBDataDir,
		"--basedir="+prefix,
		"--auth-root-authentication-method=normal",
		"--skip-name-resolve",
		"--skip-test-db",
	)
	command.Env = s.commandEnv(prefix)
	command.Dir = prefix

	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("mariadb-install-db failed: %s", strings.TrimSpace(string(output)))
	}

	return nil
}

func (s *MariaDBService) waitUntilReady(ctx context.Context, prefix string) error {
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()

	for {
		if err := s.ping(ctx, prefix); err == nil {
			return nil
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("mariadb did not become ready before timeout")
		case <-ticker.C:
		}
	}
}

func (s *MariaDBService) ping(ctx context.Context, prefix string) error {
	command := exec.CommandContext(
		ctx,
		dbmeta.AdminPath(prefix),
		"--socket="+s.paths.MariaDBSocketPath,
		"--user=root",
		"ping",
		"--silent",
	)
	command.Env = s.commandEnv(prefix)
	return command.Run()
}

func (s *MariaDBService) ensurePasswordlessRoot(ctx context.Context, prefix string) error {
	sql := strings.Join([]string{
		"CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY ''",
		"CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY ''",
		"ALTER USER 'root'@'localhost' IDENTIFIED BY ''",
		"ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY ''",
		"ALTER USER 'root'@'::1' IDENTIFIED BY ''",
		"GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION",
		"GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION",
		"GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION",
		"FLUSH PRIVILEGES",
	}, "; ") + ";"

	command := exec.CommandContext(
		ctx,
		dbmeta.ClientPath(prefix),
		"--protocol=socket",
		"--socket="+s.paths.MariaDBSocketPath,
		"--user=root",
		"--execute="+sql,
	)
	command.Env = s.commandEnv(prefix)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("mariadb root configuration failed: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

func (s *MariaDBService) runUpgrade(ctx context.Context, prefix string) error {
	if _, err := os.Stat(dbmeta.UpgradePath(prefix)); err != nil {
		return nil
	}

	command := exec.CommandContext(
		ctx,
		dbmeta.UpgradePath(prefix),
		"--socket="+s.paths.MariaDBSocketPath,
		"--user=root",
		"--force",
	)
	command.Env = s.commandEnv(prefix)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("mariadb-upgrade failed: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

func (s *MariaDBService) writeConfig(prefix string) error {
	config := `[mysqld]
datadir="` + s.paths.MariaDBDataDir + `"
basedir="` + prefix + `"
socket="` + s.paths.MariaDBSocketPath + `"
log-error="` + s.paths.MariaDBLogPath + `"
plugin-dir="` + dbmeta.PluginDir(prefix) + `"
pid-file="` + s.paths.MariaDBPIDPath + `"
port=` + strconv.Itoa(mariaDBPort) + `
bind-address=127.0.0.1
disable_log_bin
`
	return os.WriteFile(s.paths.MariaDBConfigPath, []byte(config), 0o600)
}

func (s *MariaDBService) commandEnv(prefix string) []string {
	values := map[string]string{
		"PATH":              filepath.Join(prefix, "bin") + string(os.PathListSeparator) + os.Getenv("PATH"),
		"DYLD_LIBRARY_PATH": dbmeta.LibraryDir(prefix),
	}
	for _, variable := range []string{"HOME", "TMPDIR"} {
		if value := os.Getenv(variable); value != "" {
			values[variable] = value
		}
	}
	for _, envVar := range os.Environ() {
		parts := strings.SplitN(envVar, "=", 2)
		if len(parts) != 2 {
			continue
		}
		if _, exists := values[parts[0]]; !exists {
			values[parts[0]] = parts[1]
		}
	}

	env := make([]string, 0, len(values))
	for key, value := range values {
		env = append(env, key+"="+value)
	}
	return env
}

func (s *MariaDBService) processFromPIDFile() (*os.Process, error) {
	data, err := os.ReadFile(s.paths.MariaDBPIDPath)
	if err != nil {
		return nil, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return nil, err
	}

	if !processMatches(pid, "mariadbd") {
		_ = os.Remove(s.paths.MariaDBPIDPath)
		return nil, os.ErrNotExist
	}

	return os.FindProcess(pid)
}

func processMatches(pid int, expected string) bool {
	command := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "command=")
	output, err := command.Output()
	if err != nil {
		return false
	}

	return strings.Contains(strings.TrimSpace(string(output)), expected)
}

func waitForExit(pid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		process, err := os.FindProcess(pid)
		if err != nil {
			return true
		}
		if err := process.Signal(syscall.Signal(0)); err != nil {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

func rotateLogFile(path string, maxSize int64) error {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Size() < maxSize {
		return nil
	}

	archivePath := path + ".1"
	_ = os.Remove(archivePath)
	return os.Rename(path, archivePath)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
