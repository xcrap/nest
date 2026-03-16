package config

import "time"

type Site struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Domain       string    `json:"domain"`
	RootPath     string    `json:"rootPath"`
	DocumentRoot string    `json:"documentRoot"`
	Status       string    `json:"status"`
	CreatedAt    time.Time `json:"createdAt"`
	UpdatedAt    time.Time `json:"updatedAt"`
}

type ShellIntegrationState struct {
	ZshManaged bool      `json:"zshManaged"`
	RcFile     string    `json:"rcFile"`
	BinPath    string    `json:"binPath"`
	UpdatedAt  time.Time `json:"updatedAt"`
}

type BootstrapState struct {
	TestDomainConfigured   bool      `json:"testDomainConfigured"`
	LocalCATrusted         bool      `json:"localCATrusted"`
	PrivilegedPortsReady   bool      `json:"privilegedPortsReady"`
	ResolverIPAddress      string    `json:"resolverIpAddress"`
	ResolverPort           int       `json:"resolverPort"`
	LastBootstrapCompleted time.Time `json:"lastBootstrapCompleted"`
}

type Settings struct {
	ActivePHPVersion string                `json:"activePhpVersion"`
	ShellIntegration ShellIntegrationState `json:"shellIntegration"`
	Bootstrap        BootstrapState        `json:"bootstrap"`
}

type PhpVersion struct {
	Version           string `json:"version"`
	FullVersion       string `json:"fullVersion"`
	FrankenPHPVersion string `json:"frankenphpVersion"`
	Installed         bool   `json:"installed"`
	Active            bool   `json:"active"`
	Path              string `json:"path"`
}

type MariaDBRuntime struct {
	Installed        bool   `json:"installed"`
	Status           string `json:"status"`
	InstalledVersion string `json:"installedVersion"`
	Formula          string `json:"formula"`
	Pinned           bool   `json:"pinned"`
	Prefix           string `json:"prefix"`
	BinaryPath       string `json:"binaryPath"`
	DataDir          string `json:"dataDir"`
	SocketPath       string `json:"socketPath"`
	Port             int    `json:"port"`
	RootUser         string `json:"rootUser"`
	PasswordlessRoot bool   `json:"passwordlessRoot"`
	Busy             bool   `json:"busy"`
	Activity         string `json:"activity"`
	ActivityMessage  string `json:"activityMessage"`
	LastError        string `json:"lastError"`
}

type DoctorCheck struct {
	ID      string `json:"id"`
	Status  string `json:"status"`
	Message string `json:"message"`
	FixHint string `json:"fixHint"`
}

func DefaultSettings() Settings {
	return Settings{
		ActivePHPVersion: "8.5",
		Bootstrap: BootstrapState{
			ResolverIPAddress: "127.0.0.1",
			ResolverPort:      5354,
		},
	}
}
