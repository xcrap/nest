package bootstrapstate

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	ResolverPath       = "/etc/resolver/test"
	PFAnchorPath       = "/etc/pf.anchors/dev.nest.app"
	PFConfPath         = "/etc/pf.conf"
	PFAnchorName       = "dev.nest.app"
	LegacyPFAnchorPath = "/etc/pf.anchors/dev.xcrap.nest"
	LegacyPFAnchorName = "dev.xcrap.nest"
	ResolverIP         = "127.0.0.1"
	ResolverPort       = "5354"
	SystemKeychain     = "/Library/Keychains/System.keychain"
)

var (
	securityCombinedOutput = func(args ...string) ([]byte, error) {
		return exec.Command("/usr/bin/security", args...).CombinedOutput()
	}
	securityRun = func(args ...string) error {
		return exec.Command("/usr/bin/security", args...).Run()
	}
)

func ResolverConfigured() bool {
	data, err := os.ReadFile(ResolverPath)
	if err != nil {
		return false
	}

	content := string(data)
	return strings.Contains(content, "nameserver "+ResolverIP) && strings.Contains(content, "port "+ResolverPort)
}

func PrivilegedPortsConfigured() bool {
	pfConf, err := os.ReadFile(PFConfPath)
	if err != nil {
		return false
	}

	anchor, err := os.ReadFile(PFAnchorPath)
	if err != nil {
		return false
	}

	pfConfContent := string(pfConf)
	return strings.Contains(pfConfContent, `rdr-anchor "`+PFAnchorName+`"`) &&
		strings.Contains(pfConfContent, `anchor "`+PFAnchorName+`"`) &&
		strings.Contains(pfConfContent, `load anchor "`+PFAnchorName+`" from "`+PFAnchorPath+`"`) &&
		anchorContentsMatch(string(anchor))
}

func RootCertPath(homeDir string) string {
	return filepath.Join(homeDir, "Library", "Application Support", "Caddy", "pki", "authorities", "local", "root.crt")
}

func LoginKeychainPath(homeDir string) string {
	return filepath.Join(homeDir, "Library", "Keychains", "login.keychain-db")
}

func LocalCATrusted(homeDir string) bool {
	rootCertPath := RootCertPath(homeDir)
	if _, err := os.Stat(rootCertPath); err != nil {
		return false
	}

	for _, keychainPath := range []string{LoginKeychainPath(homeDir), SystemKeychain} {
		if certTrustedInKeychain(rootCertPath, keychainPath) {
			return true
		}
	}

	return false
}

func TrustLocalCA(homeDir string) error {
	rootCertPath := RootCertPath(homeDir)
	if _, err := os.Stat(rootCertPath); err != nil {
		return fmt.Errorf("local Caddy root certificate not found at %s; start FrankenPHP once before trusting the local CA", rootCertPath)
	}

	loginKeychain := LoginKeychainPath(homeDir)
	output, err := securityCombinedOutput(
		"add-trusted-cert",
		"-r",
		"trustRoot",
		"-k",
		loginKeychain,
		rootCertPath,
	)
	if err != nil {
		return fmt.Errorf("security add-trusted-cert failed: %s", strings.TrimSpace(string(output)))
	}
	if !certTrustedInKeychain(rootCertPath, loginKeychain) {
		return errors.New("local CA trust verification failed after install")
	}

	return nil
}

func UntrustLocalCA(homeDir string) error {
	rootCertPath := RootCertPath(homeDir)
	if _, err := os.Stat(rootCertPath); err != nil {
		return fmt.Errorf("local Caddy root certificate not found at %s", rootCertPath)
	}

	for _, args := range [][]string{
		{"remove-trusted-cert", rootCertPath},
		{"remove-trusted-cert", "-d", rootCertPath},
	} {
		output, err := securityCombinedOutput(args...)
		if err == nil {
			continue
		}

		trimmed := strings.TrimSpace(string(output))
		lowerTrimmed := strings.ToLower(trimmed)
		if trimmed == "" ||
			(!strings.Contains(lowerTrimmed, "could not be found") &&
				!strings.Contains(lowerTrimmed, "not found")) {
			return fmt.Errorf("security %s failed: %s", strings.Join(args, " "), trimmed)
		}
	}
	if LocalCATrusted(homeDir) {
		return errors.New("local CA is still trusted after removal")
	}

	return nil
}

func certTrustedInKeychain(rootCertPath, keychainPath string) bool {
	if _, err := os.Stat(keychainPath); err != nil {
		return false
	}

	return securityRun(
		"verify-cert",
		"-c", rootCertPath,
		"-k", keychainPath,
		"-L",
		"-q",
	) == nil
}

func PFAnchorContents() string {
	return "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\n" +
		"rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\n"
}

func anchorContentsMatch(content string) bool {
	return strings.Contains(content, "port 80 -> 127.0.0.1 port 8080") &&
		strings.Contains(content, "port 443 -> 127.0.0.1 port 8443")
}
