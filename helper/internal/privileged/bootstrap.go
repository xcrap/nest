package privileged

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
)

const (
	resolverPath = "/etc/resolver/test"
	pfAnchorPath = "/etc/pf.anchors/dev.xcrap.nest"
	pfConfPath   = "/etc/pf.conf"
)

func BootstrapTestDomain() error {
	if os.Geteuid() != 0 {
		return errors.New("nesthelper must run as root")
	}

	if err := os.MkdirAll("/etc/resolver", 0o755); err != nil {
		return err
	}

	resolverContent := "nameserver 127.0.0.1\nport 5354\n"
	if err := os.WriteFile(resolverPath, []byte(resolverContent), 0o644); err != nil {
		return err
	}

	if err := os.WriteFile(pfAnchorPath, []byte(pfAnchorContents()), 0o644); err != nil {
		return err
	}

	if err := ensurePFConfigIncludesAnchor(); err != nil {
		return err
	}

	if err := runPFCTL("-f", pfConfPath); err != nil {
		return err
	}

	if err := runPFCTL("-E"); err != nil && !strings.Contains(err.Error(), "Token") {
		return err
	}

	return nil
}

func TrustLocalCA() error {
	if os.Geteuid() != 0 {
		return errors.New("nesthelper must run as root")
	}

	consoleUser, err := user.Lookup(consoleUsername())
	if err != nil {
		return err
	}

	rootCertPath := filepath.Join(consoleUser.HomeDir, "Library", "Application Support", "Caddy", "pki", "authorities", "local", "root.crt")
	if _, err := os.Stat(rootCertPath); err != nil {
		return fmt.Errorf("local Caddy root certificate not found at %s; start FrankenPHP once before trusting the local CA", rootCertPath)
	}

	command := exec.Command("/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k", "/Library/Keychains/System.keychain", rootCertPath)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("security add-trusted-cert failed: %s", strings.TrimSpace(string(output)))
	}

	return nil
}

func ensurePFConfigIncludesAnchor() error {
	data, err := os.ReadFile(pfConfPath)
	if err != nil {
		return err
	}

	rdrAnchorLine := "rdr-anchor \"dev.xcrap.nest\""
	anchorLine := "anchor \"dev.xcrap.nest\""
	loadLine := "load anchor \"dev.xcrap.nest\" from \"/etc/pf.anchors/dev.xcrap.nest\""
	lines := strings.Split(string(data), "\n")
	filtered := make([]string, 0, len(lines)+3)
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == rdrAnchorLine || trimmed == anchorLine || trimmed == loadLine {
			continue
		}
		filtered = append(filtered, line)
	}

	updated := make([]string, 0, len(filtered)+3)
	insertedRDR := false
	insertedAnchor := false
	for _, line := range filtered {
		updated = append(updated, line)
		trimmed := strings.TrimSpace(line)
		if !insertedRDR && trimmed == `rdr-anchor "com.apple/*"` {
			updated = append(updated, rdrAnchorLine)
			insertedRDR = true
		}
		if !insertedAnchor && trimmed == `load anchor "com.apple" from "/etc/pf.anchors/com.apple"` {
			updated = append(updated, anchorLine, loadLine)
			insertedAnchor = true
		}
	}

	if !insertedRDR {
		updated = append(updated, rdrAnchorLine)
	}
	if !insertedAnchor {
		updated = append(updated, anchorLine, loadLine)
	}

	return os.WriteFile(pfConfPath, []byte(strings.Join(updated, "\n")), 0o644)
}

func pfAnchorContents() string {
	return "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\n" +
		"rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\n"
}

func runPFCTL(args ...string) error {
	command := exec.Command("/sbin/pfctl", args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("pfctl %v failed: %s", args, strings.TrimSpace(string(output)))
	}
	return nil
}

func consoleUsername() string {
	command := exec.Command("/usr/bin/stat", "-f", "%Su", "/dev/console")
	output, err := command.Output()
	if err != nil {
		return "root"
	}
	return strings.TrimSpace(string(output))
}
