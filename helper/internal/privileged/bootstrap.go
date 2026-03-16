package privileged

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strings"

	"github.com/xcrap/nest/internal/bootstrapstate"
)

func BootstrapTestDomain() error {
	if os.Geteuid() != 0 {
		return errors.New("nesthelper must run as root")
	}

	if err := os.MkdirAll("/etc/resolver", 0o755); err != nil {
		return err
	}

	resolverContent := "nameserver " + bootstrapstate.ResolverIP + "\nport " + bootstrapstate.ResolverPort + "\n"
	if err := os.WriteFile(bootstrapstate.ResolverPath, []byte(resolverContent), 0o644); err != nil {
		return err
	}

	if err := os.WriteFile(bootstrapstate.PFAnchorPath, []byte(bootstrapstate.PFAnchorContents()), 0o644); err != nil {
		return err
	}

	if err := ensurePFConfigIncludesAnchor(); err != nil {
		return err
	}

	if err := runPFCTL("-f", bootstrapstate.PFConfPath); err != nil {
		return err
	}
	if err := runPFCTL("-E"); err != nil && !strings.Contains(err.Error(), "Token") {
		return err
	}

	if !bootstrapstate.ResolverConfigured() {
		return errors.New("resolver verification failed after bootstrap")
	}
	if !bootstrapstate.PrivilegedPortsConfigured() {
		return errors.New("pf configuration verification failed after bootstrap")
	}
	if err := verifyPFAnchorLoaded(); err != nil {
		return err
	}

	return nil
}

func UnbootstrapTestDomain() error {
	if os.Geteuid() != 0 {
		return errors.New("nesthelper must run as root")
	}

	_ = os.Remove(bootstrapstate.ResolverPath)
	_ = os.Remove(bootstrapstate.PFAnchorPath)

	if err := removePFConfigAnchor(); err != nil {
		return err
	}
	return runPFCTL("-f", bootstrapstate.PFConfPath)
}

func TrustLocalCA() error {
	if os.Geteuid() != 0 {
		return errors.New("nesthelper must run as root")
	}

	consoleUser, err := user.Lookup(consoleUsername())
	if err != nil {
		return err
	}

	rootCertPath := bootstrapstate.RootCertPath(consoleUser.HomeDir)
	if _, err := os.Stat(rootCertPath); err != nil {
		return fmt.Errorf("local Caddy root certificate not found at %s; start FrankenPHP once before trusting the local CA", rootCertPath)
	}

	command := exec.Command("/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k", bootstrapstate.SystemKeychain, rootCertPath)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("security add-trusted-cert failed: %s", strings.TrimSpace(string(output)))
	}

	if !bootstrapstate.LocalCATrusted(consoleUser.HomeDir) {
		return errors.New("local CA trust verification failed after install")
	}

	return nil
}

func UntrustLocalCA() error {
	if os.Geteuid() != 0 {
		return errors.New("nesthelper must run as root")
	}

	consoleUser, err := user.Lookup(consoleUsername())
	if err != nil {
		return err
	}

	rootCertPath := bootstrapstate.RootCertPath(consoleUser.HomeDir)
	if _, err := os.Stat(rootCertPath); err != nil {
		return fmt.Errorf("local Caddy root certificate not found at %s", rootCertPath)
	}

	command := exec.Command("/usr/bin/security", "remove-trusted-cert", "-d", rootCertPath)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("security remove-trusted-cert failed: %s", strings.TrimSpace(string(output)))
	}

	if bootstrapstate.LocalCATrusted(consoleUser.HomeDir) {
		return errors.New("local CA is still trusted after removal")
	}

	return nil
}

func ensurePFConfigIncludesAnchor() error {
	data, err := os.ReadFile(bootstrapstate.PFConfPath)
	if err != nil {
		return err
	}

	rdrAnchorLine := `rdr-anchor "` + bootstrapstate.PFAnchorName + `"`
	anchorLine := `anchor "` + bootstrapstate.PFAnchorName + `"`
	loadLine := `load anchor "` + bootstrapstate.PFAnchorName + `" from "` + bootstrapstate.PFAnchorPath + `"`
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

	return os.WriteFile(bootstrapstate.PFConfPath, []byte(strings.Join(updated, "\n")), 0o644)
}

func removePFConfigAnchor() error {
	data, err := os.ReadFile(bootstrapstate.PFConfPath)
	if err != nil {
		return err
	}

	rdrAnchorLine := `rdr-anchor "` + bootstrapstate.PFAnchorName + `"`
	anchorLine := `anchor "` + bootstrapstate.PFAnchorName + `"`
	loadLine := `load anchor "` + bootstrapstate.PFAnchorName + `" from "` + bootstrapstate.PFAnchorPath + `"`
	lines := strings.Split(string(data), "\n")
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == rdrAnchorLine || trimmed == anchorLine || trimmed == loadLine {
			continue
		}
		filtered = append(filtered, line)
	}

	return os.WriteFile(bootstrapstate.PFConfPath, []byte(strings.Join(filtered, "\n")), 0o644)
}

func verifyPFAnchorLoaded() error {
	command := exec.Command("/sbin/pfctl", "-a", bootstrapstate.PFAnchorName, "-s", "nat")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("pfctl anchor verification failed: %s", strings.TrimSpace(string(output)))
	}

	content := strings.TrimSpace(string(output))
	if !strings.Contains(content, "127.0.0.1 port 8080") || !strings.Contains(content, "127.0.0.1 port 8443") {
		return errors.New("pf anchor is loaded but expected redirect rules are missing")
	}
	return nil
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
