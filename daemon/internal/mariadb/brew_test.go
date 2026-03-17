package mariadb

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFormulaDefaultsToPinnedVersionedFormula(t *testing.T) {
	t.Setenv("NEST_MARIADB_FORMULA", "")

	if value := Formula(); value != "mariadb@10.11" {
		t.Fatalf("expected default formula mariadb@10.11, got %s", value)
	}
}

func TestFormulaRespectsOverride(t *testing.T) {
	t.Setenv("NEST_MARIADB_FORMULA", "mariadb@11.4")

	if value := Formula(); value != "mariadb@11.4" {
		t.Fatalf("expected overridden formula, got %s", value)
	}
}

func TestClientPathFallsBackToMariaDBBinary(t *testing.T) {
	tempDir := t.TempDir()
	binDir := filepath.Join(tempDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir bin: %v", err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "mariadb"), []byte(""), 0o755); err != nil {
		t.Fatalf("write mariadb stub: %v", err)
	}

	if path := ClientPath(tempDir); path != filepath.Join(binDir, "mariadb") {
		t.Fatalf("expected mariadb fallback path, got %s", path)
	}
}

func TestEnsureInstalledRecoversFromBrewLinkFailureWhenFormulaIsInstalled(t *testing.T) {
	tempDir := t.TempDir()
	brewPath := filepath.Join(tempDir, "brew")
	script := `#!/bin/sh
cmd="$1"
shift
case "$cmd" in
  list)
    if [ "$1" = "--versions" ]; then
      exit 1
    fi
    if [ "$1" = "--pinned" ]; then
      exit 0
    fi
    ;;
  install)
    echo "Error: The 'brew link' step did not complete successfully." >&2
    exit 1
    ;;
  pin)
    exit 0
    ;;
esac
exit 0
`
	if err := os.WriteFile(brewPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write brew stub: %v", err)
	}

	t.Setenv("PATH", tempDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	oldDetectRuntime := detectRuntime
	detectCalls := 0
	detectRuntime = func(ctx context.Context) (Runtime, error) {
		detectCalls++
		if detectCalls == 1 {
			return Runtime{Formula: Formula()}, nil
		}
		return Runtime{
			Formula:          Formula(),
			Installed:        true,
			Pinned:           true,
			Prefix:           "/opt/homebrew/opt/" + Formula(),
			InstalledVersion: "10.11.16",
		}, nil
	}
	t.Cleanup(func() {
		detectRuntime = oldDetectRuntime
	})

	runtime, err := EnsureInstalled(context.Background(), nil)
	if err != nil {
		t.Fatalf("EnsureInstalled returned error: %v", err)
	}
	if !runtime.Installed {
		t.Fatal("expected runtime to be installed after recovering from brew install failure")
	}
	if !runtime.Pinned {
		t.Fatal("expected runtime to be pinned after recovery")
	}
}

func TestEnsureInstalledReturnsImmediatelyWhenRuntimeAlreadyPinned(t *testing.T) {
	tempDir := t.TempDir()
	brewPath := filepath.Join(tempDir, "brew")
	outputPath := filepath.Join(tempDir, "brew-called.txt")
	script := `#!/bin/sh
echo "$@" >> "` + outputPath + `"
exit 0
`
	if err := os.WriteFile(brewPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write brew stub: %v", err)
	}

	t.Setenv("PATH", tempDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	oldDetectRuntime := detectRuntime
	detectCalls := 0
	detectRuntime = func(ctx context.Context) (Runtime, error) {
		detectCalls++
		return Runtime{
			Formula:          Formula(),
			Installed:        true,
			Pinned:           true,
			Prefix:           "/opt/homebrew/opt/" + Formula(),
			InstalledVersion: "10.11.16",
		}, nil
	}
	t.Cleanup(func() {
		detectRuntime = oldDetectRuntime
	})

	var progress []string
	runtime, err := EnsureInstalled(context.Background(), func(message string) {
		progress = append(progress, message)
	})
	if err != nil {
		t.Fatalf("EnsureInstalled returned error: %v", err)
	}
	if !runtime.Installed || !runtime.Pinned {
		t.Fatalf("expected installed pinned runtime, got %+v", runtime)
	}
	if detectCalls != 1 {
		t.Fatalf("expected one detect call, got %d", detectCalls)
	}
	if len(progress) != 0 {
		t.Fatalf("expected no progress messages, got %v", progress)
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("expected brew not to run, stat err=%v", err)
	}
}

func TestRunBrewDisablesAutoUpdateAndEnvHints(t *testing.T) {
	tempDir := t.TempDir()
	brewPath := filepath.Join(tempDir, "brew")
	outputPath := filepath.Join(tempDir, "env.txt")
	script := `#!/bin/sh
printf '%s\n' "$HOMEBREW_NO_AUTO_UPDATE" "$HOMEBREW_NO_ENV_HINTS" > "` + outputPath + `"
exit 0
`
	if err := os.WriteFile(brewPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write brew stub: %v", err)
	}

	if err := runBrew(context.Background(), brewPath, "install", Formula()); err != nil {
		t.Fatalf("runBrew returned error: %v", err)
	}

	data, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read env output: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected two environment lines, got %q", string(data))
	}
	if lines[0] != "1" {
		t.Fatalf("expected HOMEBREW_NO_AUTO_UPDATE=1, got %q", lines[0])
	}
	if lines[1] != "1" {
		t.Fatalf("expected HOMEBREW_NO_ENV_HINTS=1, got %q", lines[1])
	}
}
