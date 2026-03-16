package services

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	fpmeta "github.com/xcrap/nest/daemon/internal/frankenphp"
	"github.com/xcrap/nest/daemon/internal/state"
)

type FrankenPHPService struct {
	paths state.Paths
}

func NewFrankenPHPService(paths state.Paths) *FrankenPHPService {
	return &FrankenPHPService{paths: paths}
}

func (s *FrankenPHPService) Install(ctx context.Context) error {
	return fpmeta.InstallBinary(ctx, s.paths.FrankenPHPPath())
}

func (s *FrankenPHPService) Start(ctx context.Context, configPath string) error {
	if _, err := os.Stat(s.paths.FrankenPHPPath()); err != nil {
		if installErr := s.Install(ctx); installErr != nil {
			return fmt.Errorf("frankenphp is missing and auto-install failed: %w", installErr)
		}
	}

	if status, _ := s.Status(); status == "running" {
		return nil
	}

	if err := rotateLogFile(s.paths.FrankenPHPLogPath, 10<<20); err != nil {
		return err
	}

	logFile, err := os.OpenFile(s.paths.FrankenPHPLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}

	command := exec.Command(s.paths.FrankenPHPPath(), "run", "--config", configPath, "--adapter", "caddyfile")
	command.Env = append(os.Environ(), "PHP_INI_SCAN_DIR="+s.paths.ConfigDir)
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return err
	}

	if err := os.WriteFile(s.paths.FrankenPHPPIDPath, []byte(strconv.Itoa(command.Process.Pid)), 0o600); err != nil {
		_ = command.Process.Kill()
		_ = logFile.Close()
		return err
	}

	go func() {
		_ = command.Wait()
		_ = logFile.Close()
	}()

	readyCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := s.waitUntilReady(readyCtx); err != nil {
		_ = command.Process.Kill()
		_ = os.Remove(s.paths.FrankenPHPPIDPath)
		return err
	}

	return nil
}

func (s *FrankenPHPService) Stop() error {
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

	return os.Remove(s.paths.FrankenPHPPIDPath)
}

func (s *FrankenPHPService) Reload() error {
	if status, _ := s.Status(); status != "running" {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return s.Start(ctx, s.paths.CaddyfilePath)
	}

	command := exec.Command(s.paths.FrankenPHPPath(), "reload", "--config", s.paths.CaddyfilePath, "--adapter", "caddyfile")
	output, err := command.CombinedOutput()
	if err == nil {
		return nil
	}

	if status, _ := s.Status(); status != "running" {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return s.Start(ctx, s.paths.CaddyfilePath)
	}

	return fmt.Errorf("frankenphp reload failed: %s", strings.TrimSpace(string(output)))
}

func (s *FrankenPHPService) Status() (string, error) {
	process, err := s.processFromPIDFile()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "stopped", nil
		}
		return "unknown", err
	}
	if err := process.Signal(syscall.Signal(0)); err != nil {
		_ = os.Remove(s.paths.FrankenPHPPIDPath)
		return "stopped", nil
	}
	return "running", nil
}

func (s *FrankenPHPService) processFromPIDFile() (*os.Process, error) {
	data, err := os.ReadFile(s.paths.FrankenPHPPIDPath)
	if err != nil {
		return nil, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return nil, err
	}

	if !processMatches(pid, "frankenphp") {
		_ = os.Remove(s.paths.FrankenPHPPIDPath)
		return nil, os.ErrNotExist
	}

	return os.FindProcess(pid)
}

func (s *FrankenPHPService) waitUntilReady(ctx context.Context) error {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()

	for {
		conn, err := net.DialTimeout("tcp", "127.0.0.1:2019", 500*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return nil
		}

		select {
		case <-ctx.Done():
			return errors.New("frankenphp admin port did not become ready before timeout")
		case <-ticker.C:
		}
	}
}
