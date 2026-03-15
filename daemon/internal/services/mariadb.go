package services

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/installutil"
	dbmeta "github.com/xcrap/nest/daemon/internal/mariadb"
	"github.com/xcrap/nest/daemon/internal/state"
)

const mariaDBPort = 3306
const mariaDBRuntimeMarker = ".nest-runtime-normalized"

var systemDatabaseNames = map[string]struct{}{
	"mysql":              {},
	"performance_schema": {},
	"sys":                {},
	"test":               {},
}

type MariaDBService struct {
	paths state.Paths
	mu    sync.Mutex
	task  mariaDBTaskState
}

func NewMariaDBService(paths state.Paths) *MariaDBService {
	return &MariaDBService{paths: paths}
}

type mariaDBTaskState struct {
	Busy    bool
	Action  string
	Message string
	Error   string
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
	if err := s.beginTask("install", "Preparing MariaDB runtime"); err != nil {
		return err
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
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
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		err := s.start(ctx, s.updateTask)
		s.finishTask(err)
	}()

	return nil
}

func (s *MariaDBService) RuntimeStatus(ctx context.Context) (config.MariaDBRuntime, error) {
	return s.runtimeStatusForRelease(ctx, dbmeta.PinnedRelease()), nil
}

func (s *MariaDBService) CheckForUpdates(ctx context.Context) (config.MariaDBRuntime, error) {
	release, err := dbmeta.DiscoverLatestRelease(ctx)
	if err != nil {
		return s.runtimeStatusForRelease(ctx, dbmeta.PinnedRelease()), nil
	}
	return s.runtimeStatusForRelease(ctx, release), nil
}

func (s *MariaDBService) Install(ctx context.Context) error {
	return s.install(ctx, nil)
}

func (s *MariaDBService) install(ctx context.Context, progress func(string)) error {
	release, err := dbmeta.DiscoverLatestRelease(ctx)
	if err != nil {
		release = dbmeta.PinnedRelease()
	}
	if progress != nil {
		progress("Installing MariaDB " + release.Version)
	}
	return s.installRelease(ctx, release)
}

func (s *MariaDBService) Start(ctx context.Context) error {
	return s.start(ctx, nil)
}

func (s *MariaDBService) start(ctx context.Context, progress func(string)) error {
	if status, _ := s.Status(); status == "running" {
		return nil
	}

	if !s.isInstalled() {
		if progress != nil {
			progress("Installing MariaDB runtime")
		}
		if err := s.install(ctx, progress); err != nil {
			return fmt.Errorf("mariadb is missing and auto-install failed: %w", err)
		}
	}

	version, _, installed := s.installedVersion()
	if !installed {
		return fmt.Errorf("mariadb is not installed")
	}
	if progress != nil {
		progress("Preparing MariaDB runtime")
	}
	if err := normalizeMariaDBRuntime(version, s.paths); err != nil {
		return err
	}
	if progress != nil {
		progress("Writing MariaDB configuration")
	}
	if err := s.writeConfig(version); err != nil {
		return err
	}
	if progress != nil {
		progress("Initializing MariaDB data directory")
	}
	if err := s.ensureInitialized(ctx); err != nil {
		return err
	}

	logFile, err := os.OpenFile(s.paths.MariaDBLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}

	command := exec.Command(s.paths.MariaDBServerPath(), "--defaults-file="+s.paths.MariaDBConfigPath)
	command.Env = s.commandEnv()
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		logFile.Close()
		return err
	}

	if err := os.WriteFile(s.paths.MariaDBPIDPath, []byte(strconv.Itoa(command.Process.Pid)), 0o644); err != nil {
		logFile.Close()
		return err
	}

	go func() {
		_ = command.Wait()
		_ = logFile.Close()
	}()

	if progress != nil {
		progress("Waiting for MariaDB to accept connections")
	}
	readyCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := s.waitUntilReady(readyCtx); err != nil {
		_ = command.Process.Kill()
		_ = os.Remove(s.paths.MariaDBPIDPath)
		return err
	}

	if progress != nil {
		progress("Configuring root access")
	}
	return s.ensurePasswordlessRoot(readyCtx)
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

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if err := process.Signal(syscall.Signal(0)); err != nil {
			break
		}
		time.Sleep(200 * time.Millisecond)
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

func (s *MariaDBService) runtimeStatusForRelease(_ context.Context, release dbmeta.Release) config.MariaDBRuntime {
	installedVersion, binaryPath, installed := s.installedVersion()
	status, err := s.Status()
	if err != nil {
		status = "unknown"
	}
	task := s.snapshotTask()

	return config.MariaDBRuntime{
		Installed:        installed,
		Status:           status,
		InstalledVersion: installedVersion,
		AvailableVersion: release.Version,
		UpdateAvailable:  installed && release.Version != "" && compareVersions(installedVersion, release.Version) < 0,
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

func (s *MariaDBService) installRelease(ctx context.Context, release dbmeta.Release) error {
	versionDir := filepath.Join(s.paths.MariaDBVersionsDir, release.Version)
	archivePath := versionDir + ".zip"
	extractDir := versionDir + ".extract"

	if _, err := os.Stat(filepath.Join(versionDir, "bin", "mariadbd")); err == nil {
		if err := normalizeMariaDBRuntime(release.Version, s.paths); err != nil {
			return err
		}
		currentLink := s.paths.ActiveMariaDBDir()
		_ = os.Remove(currentLink)
		if err := os.Symlink(versionDir, currentLink); err != nil {
			return err
		}
		return s.syncClientSymlinks()
	}

	if err := os.RemoveAll(extractDir); err != nil {
		return err
	}
	if err := os.RemoveAll(versionDir); err != nil {
		return err
	}

	if err := installutil.DownloadToFile(ctx, release.ArchiveURL, archivePath, release.SHA256); err != nil {
		return err
	}
	defer os.Remove(archivePath)

	if err := os.MkdirAll(extractDir, 0o755); err != nil {
		return err
	}
	if err := installutil.ExtractZip(archivePath, extractDir); err != nil {
		return err
	}
	if err := promoteExtractedArchive(extractDir, versionDir); err != nil {
		return err
	}
	if err := normalizeMariaDBRuntime(release.Version, s.paths); err != nil {
		return err
	}

	currentLink := s.paths.ActiveMariaDBDir()
	_ = os.Remove(currentLink)
	if err := os.Symlink(versionDir, currentLink); err != nil {
		return err
	}

	return s.syncClientSymlinks()
}

func (s *MariaDBService) syncClientSymlinks() error {
	symlinks := map[string]string{
		s.paths.MySQLSymlinkPath():        s.paths.MariaDBClientPath(),
		s.paths.MySQLDumpSymlinkPath():    s.paths.MariaDBDumpPath(),
		s.paths.MariaDBSymlinkPath():      filepath.Join(s.paths.ActiveMariaDBDir(), "bin", "mariadb"),
		s.paths.MariaDBAdminSymlinkPath(): s.paths.MariaDBAdminPath(),
	}

	for linkPath, target := range symlinks {
		_ = os.Remove(linkPath)
		if err := os.Symlink(target, linkPath); err != nil {
			return err
		}
	}

	return nil
}

func (s *MariaDBService) ensureInitialized(ctx context.Context) error {
	if _, err := os.Stat(filepath.Join(s.paths.MariaDBDataDir, "mysql", "db.opt")); err == nil {
		return nil
	}

	if err := os.MkdirAll(s.paths.MariaDBDataDir, 0o755); err != nil {
		return err
	}

	root, cleanup, err := s.prepareInstallDBPaths()
	if err != nil {
		return err
	}
	defer cleanup()

	command := exec.CommandContext(
		ctx,
		filepath.Join(root, "current", "scripts", "mariadb-install-db"),
		"--no-defaults",
		"--datadir="+filepath.Join(root, "data"),
		"--basedir="+filepath.Join(root, "current"),
		"--auth-root-authentication-method=normal",
		"--skip-name-resolve",
		"--skip-test-db",
	)
	command.Env = s.commandEnv()
	command.Dir = filepath.Join(root, "current")

	output, err := command.CombinedOutput()
	if err != nil {
		_ = os.RemoveAll(s.paths.MariaDBDataDir)
		return fmt.Errorf("mariadb-install-db failed: %s", strings.TrimSpace(string(output)))
	}

	return nil
}

func (s *MariaDBService) waitUntilReady(ctx context.Context) error {
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()

	for {
		if err := s.ping(ctx); err == nil {
			return nil
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("mariadb did not become ready before timeout")
		case <-ticker.C:
		}
	}
}

func (s *MariaDBService) ping(ctx context.Context) error {
	command := exec.CommandContext(
		ctx,
		s.paths.MariaDBAdminPath(),
		"--socket="+s.paths.MariaDBSocketPath,
		"--user=root",
		"ping",
		"--silent",
	)
	command.Env = s.commandEnv()
	return command.Run()
}

func (s *MariaDBService) ensurePasswordlessRoot(ctx context.Context) error {
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
		s.paths.MariaDBClientPath(),
		"--protocol=socket",
		"--socket="+s.paths.MariaDBSocketPath,
		"--user=root",
		"--execute="+sql,
	)
	command.Env = s.commandEnv()
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("mariadb root configuration failed: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

func (s *MariaDBService) runUpgrade(ctx context.Context) error {
	command := exec.CommandContext(
		ctx,
		s.paths.MariaDBUpgradePath(),
		"--socket="+s.paths.MariaDBSocketPath,
		"--user=root",
		"--force",
	)
	command.Env = s.commandEnv()
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("mariadb-upgrade failed: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

func (s *MariaDBService) writeConfig(version string) error {
	config := `[mysqld]
datadir="` + s.paths.MariaDBDataDir + `"
basedir="` + filepath.Join(s.paths.MariaDBVersionsDir, version) + `"
socket="` + s.paths.MariaDBSocketPath + `"
log-error="` + s.paths.MariaDBLogPath + `"
plugin-dir="` + filepath.Join(s.paths.MariaDBVersionsDir, version, "lib", "plugin") + `"
pid-file="` + s.paths.MariaDBPIDPath + `"
port=` + strconv.Itoa(mariaDBPort) + `
bind-address=127.0.0.1
disable_log_bin
`
	return os.WriteFile(s.paths.MariaDBConfigPath, []byte(config), 0o644)
}

func (s *MariaDBService) installedVersion() (string, string, bool) {
	if resolved, err := filepath.EvalSymlinks(s.paths.ActiveMariaDBDir()); err == nil {
		binaryPath := filepath.Join(resolved, "bin", "mariadbd")
		if _, err := os.Stat(binaryPath); err == nil {
			return filepath.Base(resolved), binaryPath, true
		}
	}

	entries, err := os.ReadDir(s.paths.MariaDBVersionsDir)
	if err != nil {
		return "", "", false
	}

	versions := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || entry.Name() == "current" {
			continue
		}
		versions = append(versions, entry.Name())
	}
	sort.Slice(versions, func(i, j int) bool {
		return compareVersions(versions[i], versions[j]) > 0
	})
	for _, version := range versions {
		binaryPath := filepath.Join(s.paths.MariaDBVersionsDir, version, "bin", "mariadbd")
		if _, err := os.Stat(binaryPath); err == nil {
			return version, binaryPath, true
		}
	}

	return "", "", false
}

func (s *MariaDBService) isInstalled() bool {
	_, _, installed := s.installedVersion()
	return installed
}

func (s *MariaDBService) userDatabases() ([]string, error) {
	entries, err := os.ReadDir(s.paths.MariaDBDataDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}

	databases := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if _, ok := systemDatabaseNames[entry.Name()]; ok {
			continue
		}
		databases = append(databases, entry.Name())
	}
	sort.Strings(databases)
	return databases, nil
}

func (s *MariaDBService) commandEnv() []string {
	activeDir := s.paths.ActiveMariaDBDir()
	libraryPath := filepath.Join(activeDir, "lib")
	binPath := filepath.Join(activeDir, "bin")

	values := map[string]string{
		"PATH":              binPath + string(os.PathListSeparator) + os.Getenv("PATH"),
		"DYLD_LIBRARY_PATH": libraryPath,
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

	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	env := make([]string, 0, len(values))
	for _, key := range keys {
		env = append(env, key+"="+values[key])
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
	return os.FindProcess(pid)
}

func (s *MariaDBService) prepareInstallDBPaths() (string, func(), error) {
	root := filepath.Join(os.TempDir(), fmt.Sprintf("nest-mariadb-%d", os.Getpid()))
	if err := os.RemoveAll(root); err != nil {
		return "", nil, err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", nil, err
	}

	links := map[string]string{
		filepath.Join(root, "current"): s.paths.ActiveMariaDBDir(),
		filepath.Join(root, "data"):    s.paths.MariaDBDataDir,
	}
	for linkPath, target := range links {
		if err := os.Symlink(target, linkPath); err != nil {
			_ = os.RemoveAll(root)
			return "", nil, err
		}
	}

	return root, func() {
		_ = os.RemoveAll(root)
	}, nil
}

func promoteExtractedArchive(extractDir, versionDir string) error {
	sourceDir, err := extractedSourceDir(extractDir)
	if err != nil {
		return err
	}

	if sourceDir != extractDir {
		if err := os.Rename(sourceDir, versionDir); err != nil {
			return err
		}
		return os.RemoveAll(extractDir)
	}

	if err := os.MkdirAll(versionDir, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(extractDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := os.Rename(filepath.Join(extractDir, entry.Name()), filepath.Join(versionDir, entry.Name())); err != nil {
			return err
		}
	}
	return os.RemoveAll(extractDir)
}

func normalizeMariaDBRuntime(version string, paths state.Paths) error {
	versionDir := filepath.Join(paths.MariaDBVersionsDir, version)
	markerPath := filepath.Join(versionDir, mariaDBRuntimeMarker)
	if _, err := os.Stat(markerPath); err == nil {
		return nil
	}

	for _, path := range runtimeNormalizationTargets(versionDir) {
		if err := rewriteMariaDBLinks(path, versionDir); err != nil {
			return err
		}
		if err := signMariaDBBinary(path); err != nil {
			return err
		}
	}
	if err := os.WriteFile(markerPath, []byte(version+"\n"), 0o644); err != nil {
		return err
	}
	return nil
}

func runtimeNormalizationTargets(versionDir string) []string {
	candidates := []string{
		filepath.Join(versionDir, "bin", "mariadbd"),
		filepath.Join(versionDir, "bin", "mariadb"),
		filepath.Join(versionDir, "bin", "mariadb-admin"),
		filepath.Join(versionDir, "bin", "mariadb-dump"),
		filepath.Join(versionDir, "bin", "mariadb-upgrade"),
		filepath.Join(versionDir, "lib", "libssl.3.dylib"),
		filepath.Join(versionDir, "lib", "libcrypto.3.dylib"),
	}
	targets := make([]string, 0, len(candidates))
	seen := make(map[string]struct{})

	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err != nil {
			continue
		}
		if _, ok := seen[candidate]; ok {
			continue
		}
		seen[candidate] = struct{}{}
		targets = append(targets, candidate)
	}

	sort.Strings(targets)
	return targets
}

func rewriteMariaDBLinks(path, versionDir string) error {
	args := make([]string, 0, 8)

	if installName, err := machoInstallName(path); err == nil {
		if rewritten, ok := rewriteLegacyInstallName(path, versionDir, installName); ok {
			args = append(args, "-id", rewritten)
		}
	}

	linkedLibraries, err := machoLinkedLibraries(path)
	if err != nil {
		return nil
	}
	for _, library := range linkedLibraries {
		rewritten, ok := rewriteLegacyInstallName(path, versionDir, library)
		if !ok {
			continue
		}
		args = append(args, "-change", library, rewritten)
	}

	if len(args) == 0 {
		return nil
	}
	args = append(args, path)

	output, err := exec.Command("install_name_tool", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("rewrite mariadb runtime links for %s: %s", path, strings.TrimSpace(string(output)))
	}
	return nil
}

func signMariaDBBinary(path string) error {
	output, err := exec.Command("codesign", "--force", "--sign", "-", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("sign mariadb runtime binary %s: %s", path, strings.TrimSpace(string(output)))
	}
	return nil
}

func rewriteLegacyInstallName(path, versionDir, current string) (string, bool) {
	currentPath := filepath.ToSlash(current)
	if !strings.HasPrefix(currentPath, "/Users/Shared/") || !strings.Contains(currentPath, "/services/mariadb/") {
		return "", false
	}

	localTarget := filepath.Join(versionDir, "lib", filepath.Base(current))
	if _, err := os.Stat(localTarget); err != nil {
		return "", false
	}

	relativeTarget, err := filepath.Rel(filepath.Dir(path), localTarget)
	if err != nil {
		return "", false
	}
	return "@loader_path/" + filepath.ToSlash(relativeTarget), true
}

func machoInstallName(path string) (string, error) {
	output, err := exec.Command("otool", "-D", path).CombinedOutput()
	if err != nil {
		return "", err
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) < 2 {
		return "", fmt.Errorf("no install name found")
	}
	return strings.Fields(strings.TrimSpace(lines[1]))[0], nil
}

func machoLinkedLibraries(path string) ([]string, error) {
	output, err := exec.Command("otool", "-L", path).CombinedOutput()
	if err != nil {
		return nil, err
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) < 2 {
		return nil, fmt.Errorf("no linked libraries found")
	}

	linkedLibraries := make([]string, 0, len(lines)-1)
	for _, line := range lines[1:] {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) == 0 {
			continue
		}
		linkedLibraries = append(linkedLibraries, fields[0])
	}
	return linkedLibraries, nil
}

func extractedSourceDir(extractDir string) (string, error) {
	entries, err := os.ReadDir(extractDir)
	if err != nil {
		return "", err
	}
	if len(entries) == 1 && entries[0].IsDir() {
		return filepath.Join(extractDir, entries[0].Name()), nil
	}
	return extractDir, nil
}

func compareVersions(left, right string) int {
	leftParts := versionParts(left)
	rightParts := versionParts(right)
	size := len(leftParts)
	if len(rightParts) > size {
		size = len(rightParts)
	}

	for index := 0; index < size; index++ {
		var leftValue, rightValue int
		if index < len(leftParts) {
			leftValue = leftParts[index]
		}
		if index < len(rightParts) {
			rightValue = rightParts[index]
		}
		switch {
		case leftValue > rightValue:
			return 1
		case leftValue < rightValue:
			return -1
		}
	}

	return 0
}

func versionParts(version string) []int {
	parts := strings.Split(version, ".")
	values := make([]int, 0, len(parts))
	for _, part := range parts {
		number, err := strconv.Atoi(part)
		if err != nil {
			values = append(values, 0)
			continue
		}
		values = append(values, number)
	}
	return values
}
