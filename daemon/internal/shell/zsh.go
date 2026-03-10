package shell

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/xcrap/nest/daemon/internal/config"
)

const (
	beginMarker = "# >>> nest shell integration >>>"
	endMarker   = "# <<< nest shell integration <<<"
)

func ResolveZshRC() (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(homeDir, ".zshrc"), nil
}

func ManagedBlock(binPath string) string {
	return beginMarker + "\n" +
		"export PATH=\"" + binPath + ":$PATH\"\n" +
		endMarker + "\n"
}

func EnsureZshIntegration(rcPath, binPath string) (config.ShellIntegrationState, error) {
	if strings.TrimSpace(binPath) == "" {
		return config.ShellIntegrationState{}, errors.New("bin path is required")
	}

	if err := os.MkdirAll(filepath.Dir(rcPath), 0o755); err != nil {
		return config.ShellIntegrationState{}, err
	}

	current, err := os.ReadFile(rcPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return config.ShellIntegrationState{}, err
	}

	block := ManagedBlock(binPath)
	content := replaceManagedBlock(string(current), block)
	if err := os.WriteFile(rcPath, []byte(content), 0o644); err != nil {
		return config.ShellIntegrationState{}, err
	}

	return config.ShellIntegrationState{
		ZshManaged: true,
		RcFile:     rcPath,
		BinPath:    binPath,
		UpdatedAt:  time.Now().UTC(),
	}, nil
}

func HasManagedZshBlock(content string) bool {
	return strings.Contains(content, beginMarker) && strings.Contains(content, endMarker)
}

func replaceManagedBlock(content, block string) string {
	if !HasManagedZshBlock(content) {
		if strings.TrimSpace(content) == "" {
			return block
		}
		if !strings.HasSuffix(content, "\n") {
			content += "\n"
		}
		return content + "\n" + block
	}

	start := strings.Index(content, beginMarker)
	end := strings.Index(content, endMarker)
	if start == -1 || end == -1 || end < start {
		return block
	}
	end += len(endMarker)

	var builder strings.Builder
	builder.WriteString(content[:start])
	if start > 0 && !strings.HasSuffix(builder.String(), "\n") {
		builder.WriteString("\n")
	}
	builder.WriteString(block)
	if end < len(content) {
		remainder := strings.TrimLeft(content[end:], "\n")
		if remainder != "" {
			builder.WriteString("\n")
			builder.WriteString(remainder)
		}
	}

	return builder.String()
}
