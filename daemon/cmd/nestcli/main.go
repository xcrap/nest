package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/xcrap/nest/daemon/internal/api"
	"github.com/xcrap/nest/daemon/internal/app"
	"github.com/xcrap/nest/daemon/internal/config"
	"github.com/xcrap/nest/daemon/internal/shell"
	"github.com/xcrap/nest/daemon/internal/sites"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	application, err := app.New()
	exitOnError("create app", err)
	exitOnError("bootstrap app", application.Bootstrap())

	client := api.New(application.Paths.SocketPath)
	command := os.Args[1]

	switch command {
	case "site":
		handleSite(client)
	case "php":
		handlePHP(client)
	case "composer":
		handleComposer(client)
	case "mariadb":
		handleMariaDB(client)
	case "services":
		handleServices(client)
	case "doctor":
		handleDoctor(application)
	case "shell":
		handleShell(application)
	case "bootstrap":
		handleBootstrap(application)
	default:
		usage()
		os.Exit(1)
	}
}

func handleSite(client *api.Client) {
	if len(os.Args) < 3 {
		usage()
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	switch os.Args[2] {
	case "list":
		var response []config.Site
		exitOnError("list sites", client.Do(ctx, "GET", "/sites", nil, &response))
		writer := tabwriter.NewWriter(os.Stdout, 2, 4, 2, ' ', 0)
		fmt.Fprintln(writer, "ID\tDOMAIN\tSTATUS\tPROJECT_FOLDER\tDOCUMENT_ROOT")
		for _, site := range response {
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\n", site.ID, site.Domain, site.Status, site.RootPath, site.DocumentRoot)
		}
		_ = writer.Flush()
	case "add":
		flags := flag.NewFlagSet("site add", flag.ExitOnError)
		name := flags.String("name", "", "site name")
		domain := flags.String("domain", "", "site domain")
		root := flags.String("root", "", "project folder")
		documentRoot := flags.String("document-root", "", "document root relative to the project folder (default: public, use . for project folder)")
		_ = flags.Parse(os.Args[3:])
		payload := sites.CreateInput{
			Name:         *name,
			Domain:       *domain,
			RootPath:     *root,
			DocumentRoot: *documentRoot,
		}
		var response config.Site
		exitOnError("add site", client.Do(ctx, "POST", "/sites", payload, &response))
		fmt.Printf("created site %s (%s)\n", response.ID, response.Domain)
	case "remove":
		requireArgs(4)
		exitOnError("remove site", client.Do(ctx, "DELETE", "/sites/"+os.Args[3], nil, nil))
		fmt.Println("site removed")
	case "start":
		requireArgs(4)
		var response config.Site
		exitOnError("start site", client.Do(ctx, "POST", "/sites/"+os.Args[3]+"/start", nil, &response))
		fmt.Printf("site %s started\n", response.Domain)
	case "stop":
		requireArgs(4)
		var response config.Site
		exitOnError("stop site", client.Do(ctx, "POST", "/sites/"+os.Args[3]+"/stop", nil, &response))
		fmt.Printf("site %s stopped\n", response.Domain)
	default:
		usage()
		os.Exit(1)
	}
}

func handleMariaDB(client *api.Client) {
	if len(os.Args) < 3 {
		usage()
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	switch os.Args[2] {
	case "status", "info":
		var response config.MariaDBRuntime
		exitOnError("mariadb status", client.Do(ctx, "GET", "/mariadb", nil, &response))
		writer := tabwriter.NewWriter(os.Stdout, 2, 4, 2, ' ', 0)
		fmt.Fprintln(writer, "INSTALLED\tSTATUS\tVERSION\tFORMULA\tPINNED\tBUSY\tACTIVITY\tDATA_DIR")
		fmt.Fprintf(
			writer,
			"%t\t%s\t%s\t%s\t%t\t%t\t%s\t%s\n",
			response.Installed,
			response.Status,
			response.InstalledVersion,
			response.Formula,
			response.Pinned,
			response.Busy,
			response.Activity,
			response.DataDir,
		)
		_ = writer.Flush()
		if response.ActivityMessage != "" {
			fmt.Println("message:", response.ActivityMessage)
		}
		if response.LastError != "" {
			fmt.Println("last_error:", response.LastError)
		}
	case "install":
		var response config.MariaDBRuntime
		exitOnError("install mariadb", client.Do(ctx, "POST", "/mariadb/install", nil, &response))
		fmt.Println("mariadb install requested")
		if response.ActivityMessage != "" {
			fmt.Println(response.ActivityMessage)
		}
	case "start":
		var response config.MariaDBRuntime
		exitOnError("start mariadb", client.Do(ctx, "POST", "/mariadb/start", nil, &response))
		fmt.Println("mariadb start requested")
		if response.ActivityMessage != "" {
			fmt.Println(response.ActivityMessage)
		}
	case "stop":
		exitOnError("stop mariadb", client.Do(ctx, "POST", "/mariadb/stop", nil, nil))
		fmt.Println("mariadb stopped")
	case "check-updates":
		var response config.MariaDBRuntime
		exitOnError("check mariadb updates", client.Do(ctx, "GET", "/mariadb/check-updates", nil, &response))
		fmt.Printf("formula=%s version=%s pinned=%t installed=%t\n", response.Formula, response.InstalledVersion, response.Pinned, response.Installed)
	default:
		usage()
		os.Exit(1)
	}
}

func handlePHP(client *api.Client) {
	if len(os.Args) < 3 {
		usage()
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	switch os.Args[2] {
	case "list":
		var response []config.PhpVersion
		exitOnError("list php versions", client.Do(ctx, "GET", "/php/versions", nil, &response))
		writer := tabwriter.NewWriter(os.Stdout, 2, 4, 2, ' ', 0)
		fmt.Fprintln(writer, "VERSION\tINSTALLED\tACTIVE\tPATH")
		for _, version := range response {
			fmt.Fprintf(writer, "%s\t%t\t%t\t%s\n", version.Version, version.Installed, version.Active, version.Path)
		}
		_ = writer.Flush()
	case "install":
		requireArgs(4)
		exitOnError("install php", client.Do(ctx, "POST", "/php/versions/install", map[string]string{"version": os.Args[3]}, nil))
		fmt.Println("php installed")
	case "activate":
		requireArgs(4)
		exitOnError("activate php", client.Do(ctx, "POST", "/php/versions/activate", map[string]string{"version": os.Args[3]}, nil))
		fmt.Println("php activated")
	default:
		usage()
		os.Exit(1)
	}
}

func handleComposer(client *api.Client) {
	if len(os.Args) < 3 {
		usage()
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	switch os.Args[2] {
	case "status", "info":
		var response config.ComposerRuntime
		exitOnError("composer status", client.Do(ctx, "GET", "/composer", nil, &response))
		printComposerRuntime(response)
	case "check-updates":
		var response config.ComposerRuntime
		exitOnError("check composer updates", client.Do(ctx, "GET", "/composer/check-updates", nil, &response))
		printComposerRuntime(response)
	case "install":
		var response config.ComposerRuntime
		exitOnError("install composer", client.Do(ctx, "POST", "/composer/install", nil, &response))
		printComposerRuntime(response)
	case "update":
		var response config.ComposerRuntime
		exitOnError("update composer", client.Do(ctx, "POST", "/composer/update", nil, &response))
		printComposerRuntime(response)
	case "rollback":
		var response config.ComposerRuntime
		exitOnError("rollback composer", client.Do(ctx, "POST", "/composer/rollback", nil, &response))
		printComposerRuntime(response)
	default:
		usage()
		os.Exit(1)
	}
}

func handleServices(client *api.Client) {
	if len(os.Args) < 3 {
		usage()
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	switch os.Args[2] {
	case "start":
		exitOnError("start services", client.Do(ctx, "POST", "/services/start", nil, nil))
		fmt.Println("frankenphp started")
	case "stop":
		exitOnError("stop services", client.Do(ctx, "POST", "/services/stop", nil, nil))
		fmt.Println("frankenphp stopped")
	case "reload":
		exitOnError("reload services", client.Do(ctx, "POST", "/services/reload", nil, nil))
		fmt.Println("frankenphp reloaded")
	case "status":
		var response map[string]string
		exitOnError("service status", client.Do(ctx, "GET", "/services/status", nil, &response))
		fmt.Println(response["status"])
	default:
		usage()
		os.Exit(1)
	}
}

func handleDoctor(application *app.App) {
	checks, err := application.Doctor.Run()
	exitOnError("doctor", err)

	writer := tabwriter.NewWriter(os.Stdout, 2, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tSTATUS\tMESSAGE\tFIX")
	for _, check := range checks {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", check.ID, check.Status, check.Message, check.FixHint)
	}
	_ = writer.Flush()
}

func handleShell(application *app.App) {
	if len(os.Args) < 4 || os.Args[2] != "integrate" || os.Args[3] != "--zsh" {
		usage()
		os.Exit(1)
	}

	rcPath, err := shell.ResolveZshRC()
	exitOnError("resolve zshrc", err)

	state, err := shell.EnsureZshIntegration(rcPath, application.Paths.BinDir)
	exitOnError("integrate shell", err)

	settings, err := application.Store.LoadSettings()
	exitOnError("load settings", err)
	settings.ShellIntegration = state
	exitOnError("save settings", application.Store.SaveSettings(settings))
	fmt.Printf("zsh integration updated in %s\n", state.RcFile)
}

func handleBootstrap(application *app.App) {
	if len(os.Args) < 3 {
		usage()
		os.Exit(1)
	}

	switch os.Args[2] {
	case "test-domain":
		if os.Geteuid() != 0 {
			exitOnError("bootstrap test-domain", fmt.Errorf("re-run with sudo or use the desktop app so Nest can invoke nesthelper with administrator privileges"))
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		exitOnError("bootstrap test-domain", application.BootstrapTestDomain(ctx))
		fmt.Println("test-domain bootstrap completed")
	case "unbootstrap-test-domain":
		if os.Geteuid() != 0 {
			exitOnError("unbootstrap test-domain", fmt.Errorf("re-run with sudo or use the desktop app so Nest can invoke nesthelper with administrator privileges"))
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		exitOnError("unbootstrap test-domain", application.UnbootstrapTestDomain(ctx))
		fmt.Println("test-domain bootstrap removed")
	case "trust-local-ca":
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		exitOnError("bootstrap trust-local-ca", application.TrustLocalCA(ctx))
		fmt.Println("local CA trusted in the login keychain")
	case "untrust-local-ca":
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		exitOnError("bootstrap untrust-local-ca", application.UntrustLocalCA(ctx))
		fmt.Println("local CA trust removed from the login keychain")
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Println("nestcli commands:")
	fmt.Println("  nestcli site list")
	fmt.Println("  nestcli site add --name NAME --domain DOMAIN --root PATH [--document-root public|.|web]")
	fmt.Println("  nestcli site remove ID")
	fmt.Println("  nestcli site start ID")
	fmt.Println("  nestcli site stop ID")
	fmt.Println("  nestcli php list")
	fmt.Println("  nestcli php install VERSION")
	fmt.Println("  nestcli php activate VERSION")
	fmt.Println("  nestcli composer status|install|update|rollback|check-updates")
	fmt.Println("  nestcli mariadb status|install|start|stop|check-updates")
	fmt.Println("  nestcli services start|stop|reload|status")
	fmt.Println("  nestcli doctor")
	fmt.Println("  nestcli shell integrate --zsh")
	fmt.Println("  sudo nestcli bootstrap test-domain")
	fmt.Println("  sudo nestcli bootstrap unbootstrap-test-domain")
	fmt.Println("  nestcli bootstrap trust-local-ca")
	fmt.Println("  nestcli bootstrap untrust-local-ca")
}

func printComposerRuntime(runtime config.ComposerRuntime) {
	writer := tabwriter.NewWriter(os.Stdout, 2, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "INSTALLED\tSTATUS\tINSTALLED_VERSION\tLATEST_VERSION\tUPDATE_AVAILABLE\tWRAPPER\tBACKUP")
	fmt.Fprintf(
		writer,
		"%t\t%s\t%s\t%s\t%t\t%t\t%t\n",
		runtime.Installed,
		runtime.Status,
		runtime.InstalledVersion,
		runtime.LatestVersion,
		runtime.UpdateAvailable,
		runtime.WrapperPresent,
		runtime.BackupAvailable,
	)
	_ = writer.Flush()
	if runtime.SourceURL != "" {
		fmt.Println("source:", runtime.SourceURL)
	}
	if runtime.ChecksumURL != "" {
		fmt.Println("checksum:", runtime.ChecksumURL)
	}
	if runtime.InstalledChecksum != "" {
		fmt.Println("installed_checksum:", runtime.InstalledChecksum)
	}
	if runtime.LatestChecksum != "" {
		fmt.Println("latest_checksum:", runtime.LatestChecksum)
	}
	if runtime.PharPath != "" {
		fmt.Println("phar:", runtime.PharPath)
	}
	if runtime.WrapperPath != "" {
		fmt.Println("wrapper:", runtime.WrapperPath)
	}
	if runtime.BackupPath != "" {
		fmt.Println("backup:", runtime.BackupPath)
	}
	if !runtime.InstalledAt.IsZero() {
		fmt.Println("installed_at:", runtime.InstalledAt.Format(time.RFC3339))
	}
	if runtime.LastError != "" {
		fmt.Println("last_error:", runtime.LastError)
	}
}

func requireArgs(count int) {
	if len(os.Args) < count {
		usage()
		os.Exit(1)
	}
}

func exitOnError(action string, err error) {
	if err == nil {
		return
	}
	fmt.Fprintf(os.Stderr, "%s: %v\n", action, err)
	os.Exit(1)
}
