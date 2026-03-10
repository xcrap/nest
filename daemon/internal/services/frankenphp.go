package services

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"

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
	_ = ctx
	if _, err := os.Stat(s.paths.FrankenPHPPath()); err != nil {
		if installErr := s.Install(ctx); installErr != nil {
			return fmt.Errorf("frankenphp is missing and auto-install failed: %w", installErr)
		}
	}

	if status, _ := s.Status(); status == "running" {
		return nil
	}

	logFile, err := os.OpenFile(s.paths.FrankenPHPLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}

	command := exec.Command(s.paths.FrankenPHPPath(), "run", "--config", configPath, "--adapter", "caddyfile")
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		logFile.Close()
		return err
	}

	if err := os.WriteFile(s.paths.FrankenPHPPIDPath, []byte(strconv.Itoa(command.Process.Pid)), 0o644); err != nil {
		logFile.Close()
		return err
	}

	go func() {
		_ = command.Wait()
		_ = logFile.Close()
	}()

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

	return os.Remove(s.paths.FrankenPHPPIDPath)
}

func (s *FrankenPHPService) Reload() error {
	command := exec.Command(s.paths.FrankenPHPPath(), "reload", "--config", s.paths.CaddyfilePath, "--adapter", "caddyfile")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("frankenphp reload failed: %s", strings.TrimSpace(string(output)))
	}
	return nil
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
	return os.FindProcess(pid)
}
