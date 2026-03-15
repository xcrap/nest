package sites

import (
	"fmt"
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

	if len(runningSites) == 0 {
		builder.WriteString("# No running sites are registered yet.\n")
		return builder.String()
	}

	for _, site := range runningSites {
		siteType := site.Type
		if siteType == "" {
			siteType = "php-app"
		} else if siteType == "php" {
			siteType = "php-app"
		} else if siteType == "laravel" {
			siteType = "laravel-app"
		}
		builder.WriteString(fmt.Sprintf("import %s %s %s\n", siteType, site.Domain, site.RootPath))
	}

	return builder.String()
}
