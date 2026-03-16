package bootstrapstate

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	ResolverPath   = "/etc/resolver/test"
	PFAnchorPath   = "/etc/pf.anchors/dev.xcrap.nest"
	PFConfPath     = "/etc/pf.conf"
	PFAnchorName   = "dev.xcrap.nest"
	ResolverIP     = "127.0.0.1"
	ResolverPort   = "5354"
	SystemKeychain = "/Library/Keychains/System.keychain"
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

func LocalCATrusted(homeDir string) bool {
	rootCertPath := RootCertPath(homeDir)
	if _, err := os.Stat(rootCertPath); err != nil {
		return false
	}

	command := exec.Command(
		"/usr/bin/security",
		"verify-cert",
		"-c", rootCertPath,
		"-k", SystemKeychain,
		"-L",
		"-q",
	)
	return command.Run() == nil
}

func PFAnchorContents() string {
	return "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\n" +
		"rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\n"
}

func anchorContentsMatch(content string) bool {
	return strings.Contains(content, "port 80 -> 127.0.0.1 port 8080") &&
		strings.Contains(content, "port 443 -> 127.0.0.1 port 8443")
}
