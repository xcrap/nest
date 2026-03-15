package sites

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/xcrap/nest/daemon/internal/config"
)

func GenerateCaddyfile(sites []config.Site, logPath string) string {
	runningSites := make([]config.Site, 0, len(sites))
	for _, site := range sites {
		if site.Status == "running" {
			runningSites = append(runningSites, site)
		}
	}

	sort.Slice(runningSites, func(i, j int) bool {
		return runningSites[i].Domain < runningSites[j].Domain
	})

	var builder strings.Builder
	builder.WriteString("{\n")
	builder.WriteString("\thttp_port 8080\n")
	builder.WriteString("\thttps_port 8443\n")
	builder.WriteString("\tadmin localhost:2019\n")
	builder.WriteString("\tlocal_certs\n")
	builder.WriteString(fmt.Sprintf("\tlog {\n\t\toutput file %q\n\t\tformat console\n\t}\n", logPath))
	builder.WriteString("}\n\n")
	builder.WriteString("import snippets/*\n\n")
	builder.WriteString("localhost {\n")
	builder.WriteString("\ttls internal\n")
	builder.WriteString("\trespond 204\n")
	builder.WriteString("}\n\n")

	if len(runningSites) == 0 {
		builder.WriteString("# No running sites are registered yet.\n")
		return builder.String()
	}

	for _, site := range runningSites {
		documentRoot := site.DocumentRoot
		if strings.TrimSpace(documentRoot) == "" {
			documentRoot = inferredDocumentRoot(site.RootPath)
		}
		documentRootPath := site.RootPath
		if documentRoot != "." {
			documentRootPath = filepath.Join(site.RootPath, documentRoot)
		}
		builder.WriteString(fmt.Sprintf("import php-app %s %s %s\n", site.Domain, site.RootPath, documentRootPath))
	}

	return builder.String()
}
