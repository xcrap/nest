package mariadb

import (
	"os"
	"path/filepath"
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
