package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
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
		fmt.Fprintln(writer, "ID\tDOMAIN\tSTATUS\tROOT")
		for _, site := range response {
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", site.ID, site.Domain, site.Status, site.RootPath)
		}
		_ = writer.Flush()
	case "add":
		flags := flag.NewFlagSet("site add", flag.ExitOnError)
		name := flags.String("name", "", "site name")
		domain := flags.String("domain", "", "site domain")
		root := flags.String("root", "", "site root")
		phpVersion := flags.String("php-version", "", "php version")
		httpsEnabled := flags.Bool("https", true, "enable https")
		_ = flags.Parse(os.Args[3:])
		payload := sites.CreateInput{
			Name:         *name,
			Domain:       *domain,
			RootPath:     *root,
			PHPVersion:   *phpVersion,
			HTTPSEnabled: *httpsEnabled,
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

	if os.Geteuid() != 0 {
		exitOnError("bootstrap test-domain", fmt.Errorf("re-run with sudo or use the desktop app so Nest can invoke nesthelper with administrator privileges"))
	}

	switch os.Args[2] {
	case "test-domain":
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		exitOnError("bootstrap test-domain", application.BootstrapTestDomain(ctx))
		fmt.Println("test-domain bootstrap completed")
	case "trust-local-ca":
		helperPath, err := app.ResolveHelperBinaryForCLI()
		exitOnError("resolve helper", err)
		command := exec.Command(helperPath, "trust", "local-ca")
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		exitOnError("bootstrap trust-local-ca", command.Run())
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Println("nestctl commands:")
	fmt.Println("  nestctl site list")
	fmt.Println("  nestctl site add --name NAME --domain DOMAIN --root PATH [--php-version VERSION] [--https=true]")
	fmt.Println("  nestctl site remove ID")
	fmt.Println("  nestctl site start ID")
	fmt.Println("  nestctl site stop ID")
	fmt.Println("  nestctl php list")
	fmt.Println("  nestctl php install VERSION")
	fmt.Println("  nestctl php activate VERSION")
	fmt.Println("  nestctl services start|stop|reload|status")
	fmt.Println("  nestctl doctor")
	fmt.Println("  nestctl shell integrate --zsh")
	fmt.Println("  nestctl bootstrap test-domain")
	fmt.Println("  sudo nestctl bootstrap trust-local-ca")
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
