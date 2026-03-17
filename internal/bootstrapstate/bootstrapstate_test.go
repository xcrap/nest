package bootstrapstate

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestTrustLocalCAUsesLoginKeychain(t *testing.T) {
	homeDir := t.TempDir()
	rootCertPath := writeTestBootstrapFiles(t, homeDir)
	loginKeychain := LoginKeychainPath(homeDir)

	restoreSecurityHooks(t)

	var addTrustedCertArgs []string
	securityCombinedOutput = func(args ...string) ([]byte, error) {
		addTrustedCertArgs = append([]string(nil), args...)
		return []byte(""), nil
	}
	securityRun = func(args ...string) error {
		if len(args) > 4 && args[0] == "verify-cert" && args[4] == loginKeychain {
			return nil
		}
		return errors.New("not trusted")
	}

	if err := TrustLocalCA(homeDir); err != nil {
		t.Fatalf("TrustLocalCA returned error: %v", err)
	}

	want := []string{
		"add-trusted-cert",
		"-r",
		"trustRoot",
		"-k",
		loginKeychain,
		rootCertPath,
	}
	if !reflect.DeepEqual(addTrustedCertArgs, want) {
		t.Fatalf("unexpected add-trusted-cert args\nwant: %#v\ngot:  %#v", want, addTrustedCertArgs)
	}
}

func TestLocalCATrustedChecksLoginKeychainFirst(t *testing.T) {
	homeDir := t.TempDir()
	_ = writeTestBootstrapFiles(t, homeDir)
	loginKeychain := LoginKeychainPath(homeDir)

	restoreSecurityHooks(t)

	var keychainChecks []string
	securityRun = func(args ...string) error {
		if len(args) > 4 && args[0] == "verify-cert" {
			keychainChecks = append(keychainChecks, args[4])
			if args[4] == loginKeychain {
				return nil
			}
		}
		return errors.New("not trusted")
	}

	if !LocalCATrusted(homeDir) {
		t.Fatal("expected LocalCATrusted to succeed when the login keychain trusts the certificate")
	}
	if len(keychainChecks) == 0 {
		t.Fatal("expected LocalCATrusted to verify at least one keychain")
	}
	if keychainChecks[0] != loginKeychain {
		t.Fatalf("expected login keychain to be checked first, got %q", keychainChecks[0])
	}
}

func TestUntrustLocalCARemovesUserAndAdminTrust(t *testing.T) {
	homeDir := t.TempDir()
	rootCertPath := writeTestBootstrapFiles(t, homeDir)

	restoreSecurityHooks(t)

	var removeCalls [][]string
	securityCombinedOutput = func(args ...string) ([]byte, error) {
		removeCalls = append(removeCalls, append([]string(nil), args...))
		return []byte(""), nil
	}
	securityRun = func(args ...string) error {
		return errors.New("not trusted")
	}

	if err := UntrustLocalCA(homeDir); err != nil {
		t.Fatalf("UntrustLocalCA returned error: %v", err)
	}

	want := [][]string{
		{"remove-trusted-cert", rootCertPath},
		{"remove-trusted-cert", "-d", rootCertPath},
	}
	if !reflect.DeepEqual(removeCalls, want) {
		t.Fatalf("unexpected remove-trusted-cert args\nwant: %#v\ngot:  %#v", want, removeCalls)
	}
}

func restoreSecurityHooks(t *testing.T) {
	t.Helper()

	oldCombinedOutput := securityCombinedOutput
	oldRun := securityRun
	t.Cleanup(func() {
		securityCombinedOutput = oldCombinedOutput
		securityRun = oldRun
	})
}

func writeTestBootstrapFiles(t *testing.T, homeDir string) string {
	t.Helper()

	rootCertPath := RootCertPath(homeDir)
	if err := os.MkdirAll(filepath.Dir(rootCertPath), 0o755); err != nil {
		t.Fatalf("mkdir root cert dir: %v", err)
	}
	if err := os.WriteFile(rootCertPath, []byte("test-cert"), 0o644); err != nil {
		t.Fatalf("write root cert: %v", err)
	}

	loginKeychain := LoginKeychainPath(homeDir)
	if err := os.MkdirAll(filepath.Dir(loginKeychain), 0o755); err != nil {
		t.Fatalf("mkdir login keychain dir: %v", err)
	}
	if err := os.WriteFile(loginKeychain, []byte("test-keychain"), 0o600); err != nil {
		t.Fatalf("write login keychain: %v", err)
	}

	return rootCertPath
}
