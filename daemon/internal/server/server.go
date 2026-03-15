package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"

	"github.com/xcrap/nest/daemon/internal/app"
	"github.com/xcrap/nest/daemon/internal/buildinfo"
	"github.com/xcrap/nest/daemon/internal/sites"
)

type Server struct {
	app *app.App
}

func New(application *app.App) *Server {
	return &Server{app: application}
}

func (s *Server) ListenAndServe(ctx context.Context) error {
	if err := os.RemoveAll(s.app.Paths.SocketPath); err != nil {
		return err
	}

	listener, err := net.Listen("unix", s.app.Paths.SocketPath)
	if err != nil {
		return err
	}
	defer listener.Close()

	if err := os.Chmod(s.app.Paths.SocketPath, 0o666); err != nil {
		return err
	}

	httpServer := &http.Server{
		Handler: s.routes(),
	}

	go func() {
		<-ctx.Done()
		_ = httpServer.Shutdown(context.Background())
	}()

	if err := s.app.StartDNS(ctx); err != nil {
		return err
	}

	if err := httpServer.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/sites", s.handleSites)
	mux.HandleFunc("/sites/", s.handleSiteActions)
	mux.HandleFunc("/services/start", s.handleServicesStart)
	mux.HandleFunc("/services/stop", s.handleServicesStop)
	mux.HandleFunc("/services/reload", s.handleServicesReload)
	mux.HandleFunc("/services/status", s.handleServicesStatus)
	mux.HandleFunc("/meta", s.handleMeta)
	mux.HandleFunc("/logs/frankenphp", s.handleFrankenPHPLogs)
	mux.HandleFunc("/php/versions", s.handlePHPVersions)
	mux.HandleFunc("/php/versions/install", s.handlePHPInstall)
	mux.HandleFunc("/php/versions/activate", s.handlePHPActivate)
	mux.HandleFunc("/mariadb", s.handleMariaDBStatus)
	mux.HandleFunc("/mariadb/check-updates", s.handleMariaDBCheckUpdates)
	mux.HandleFunc("/mariadb/install", s.handleMariaDBInstall)
	mux.HandleFunc("/mariadb/start", s.handleMariaDBStart)
	mux.HandleFunc("/mariadb/stop", s.handleMariaDBStop)
	mux.HandleFunc("/settings", s.handleSettings)
	mux.HandleFunc("/doctor", s.handleDoctor)
	mux.HandleFunc("/bootstrap/test-domain", s.handleBootstrapTestDomain)
	mux.HandleFunc("/bootstrap/trust-local-ca", s.handleTrustLocalCA)
	mux.HandleFunc("/doctor/fix", s.handleDoctorFix)
	mux.HandleFunc("/config/files", s.handleConfigFiles)
	mux.HandleFunc("/config/files/", s.handleConfigFile)
	return mux
}

func (s *Server) handleSites(writer http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		sitesList, err := s.app.Sites.List()
		if err != nil {
			writeError(writer, http.StatusInternalServerError, err)
			return
		}
		writeJSON(writer, http.StatusOK, sitesList)
	case http.MethodPost:
		var input sites.CreateInput
		if err := json.NewDecoder(request.Body).Decode(&input); err != nil {
			writeError(writer, http.StatusBadRequest, err)
			return
		}
		site, err := s.app.Sites.Create(input)
		if err != nil {
			writeError(writer, http.StatusBadRequest, err)
			return
		}
		writeJSON(writer, http.StatusCreated, site)
	default:
		writer.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleSiteActions(writer http.ResponseWriter, request *http.Request) {
	path := strings.TrimPrefix(request.URL.Path, "/sites/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		writer.WriteHeader(http.StatusNotFound)
		return
	}

	id := parts[0]
	if len(parts) == 1 {
		switch request.Method {
		case http.MethodPatch:
			var input sites.UpdateInput
			if err := json.NewDecoder(request.Body).Decode(&input); err != nil {
				writeError(writer, http.StatusBadRequest, err)
				return
			}
			site, err := s.app.Sites.Update(id, input)
			if err != nil {
				writeError(writer, http.StatusBadRequest, err)
				return
			}
			writeJSON(writer, http.StatusOK, site)
		case http.MethodDelete:
			if err := s.app.Sites.Delete(id); err != nil {
				writeError(writer, http.StatusBadRequest, err)
				return
			}
			writer.WriteHeader(http.StatusNoContent)
		default:
			writer.WriteHeader(http.StatusMethodNotAllowed)
		}
		return
	}

	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	switch parts[1] {
	case "start":
		site, err := s.app.Sites.SetStatus(id, "running")
		if err != nil {
			writeError(writer, http.StatusBadRequest, err)
			return
		}
		_ = s.app.FrankenPHP.Reload()
		writeJSON(writer, http.StatusOK, site)
	case "stop":
		site, err := s.app.Sites.SetStatus(id, "stopped")
		if err != nil {
			writeError(writer, http.StatusBadRequest, err)
			return
		}
		_ = s.app.FrankenPHP.Reload()
		writeJSON(writer, http.StatusOK, site)
	default:
		writer.WriteHeader(http.StatusNotFound)
	}
}

func (s *Server) handleServicesStart(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if err := s.app.FrankenPHP.Start(request.Context(), s.app.Paths.CaddyfilePath); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "running"})
}

func (s *Server) handleServicesStop(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if err := s.app.FrankenPHP.Stop(); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "stopped"})
}

func (s *Server) handleServicesReload(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if err := s.app.Sites.RewriteCaddyfile(); err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	if err := s.app.FrankenPHP.Reload(); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "reloaded"})
}

func (s *Server) handleServicesStatus(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	status, err := s.app.FrankenPHP.Status()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": status})
}

func (s *Server) handleMeta(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	writeJSON(writer, http.StatusOK, buildinfo.Current())
}

func (s *Server) handleFrankenPHPLogs(writer http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		data, err := os.ReadFile(s.app.Paths.FrankenPHPLogPath)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			writeError(writer, http.StatusInternalServerError, err)
			return
		}
		writeJSON(writer, http.StatusOK, map[string]string{"content": string(data)})
	case http.MethodDelete:
		if err := os.Truncate(s.app.Paths.FrankenPHPLogPath, 0); err != nil && !errors.Is(err, os.ErrNotExist) {
			writeError(writer, http.StatusInternalServerError, err)
			return
		}
		writeJSON(writer, http.StatusOK, map[string]string{"status": "cleared"})
	default:
		writer.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *Server) handlePHPVersions(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	versions, err := s.app.Runtime.SupportedVersions()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, versions)
}

func (s *Server) handlePHPInstall(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	if err := s.app.Runtime.Install(request.Context(), payload.Version); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "installed"})
}

func (s *Server) handlePHPActivate(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	if err := s.app.Runtime.Activate(payload.Version); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "active"})
}

func (s *Server) handleMariaDBStatus(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	status, err := s.app.MariaDB.RuntimeStatus(request.Context())
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, status)
}

func (s *Server) handleMariaDBCheckUpdates(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	status, err := s.app.MariaDB.CheckForUpdates(request.Context())
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, status)
}

func (s *Server) handleMariaDBInstall(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if err := s.app.MariaDB.InstallAsync(); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	status, err := s.app.MariaDB.RuntimeStatus(request.Context())
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusAccepted, status)
}

func (s *Server) handleMariaDBStart(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if err := s.app.MariaDB.StartAsync(); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	status, err := s.app.MariaDB.RuntimeStatus(request.Context())
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusAccepted, status)
}

func (s *Server) handleMariaDBStop(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if err := s.app.MariaDB.Stop(); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "stopped"})
}

func (s *Server) handleSettings(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	settings, err := s.app.Store.LoadSettings()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, settings)
}

func (s *Server) handleDoctor(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	checks, err := s.app.Doctor.Run()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, checks)
}

func (s *Server) handleDoctorFix(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	var err error
	switch payload.ID {
	case "php-symlink":
		err = s.app.FixPHPSymlink(request.Context())
	case "shell-path":
		err = s.app.FixShellPath()
	case "frankenphp-binary":
		err = s.app.FixPHPSymlink(request.Context())
	default:
		writeError(writer, http.StatusBadRequest, fmt.Errorf("no auto-fix available for %q", payload.ID))
		return
	}
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "fixed"})
}

func (s *Server) handleBootstrapTestDomain(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var err error
	if request.URL.Query().Get("skipHelper") == "1" {
		err = s.app.MarkTestDomainBootstrapped()
	} else {
		err = s.app.BootstrapTestDomain(request.Context())
	}
	if err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "bootstrapped"})
}

func (s *Server) handleTrustLocalCA(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var err error
	if request.URL.Query().Get("skipHelper") == "1" {
		err = s.app.MarkLocalCATrusted()
	} else {
		err = s.app.TrustLocalCA(request.Context())
	}
	if err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": "trusted"})
}

func (s *Server) configFileMap() map[string]string {
	return map[string]string{
		"security": s.app.Paths.SecurityConfPath,
		"php-app":  s.app.Paths.PHPAppSnippetPath(),
		"php-ini":  s.app.Paths.PHPIniPath,
	}
}

func (s *Server) handleConfigFiles(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	result := make(map[string]string)
	for name, path := range s.configFileMap() {
		content, err := s.app.Store.LoadConfigFile(path)
		if err != nil {
			result[name] = ""
			continue
		}
		result[name] = content
	}
	writeJSON(writer, http.StatusOK, result)
}

func (s *Server) handleConfigFile(writer http.ResponseWriter, request *http.Request) {
	name := strings.TrimPrefix(request.URL.Path, "/config/files/")
	filePath, ok := s.configFileMap()[name]
	if !ok {
		writeError(writer, http.StatusNotFound, fmt.Errorf("unknown config file: %s", name))
		return
	}

	switch request.Method {
	case http.MethodGet:
		content, err := s.app.Store.LoadConfigFile(filePath)
		if err != nil {
			writeError(writer, http.StatusInternalServerError, err)
			return
		}
		writeJSON(writer, http.StatusOK, map[string]string{"content": content})
	case http.MethodPut:
		var payload struct {
			Content string `json:"content"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			writeError(writer, http.StatusBadRequest, err)
			return
		}
		if err := s.app.Store.SaveConfigFile(filePath, payload.Content); err != nil {
			writeError(writer, http.StatusInternalServerError, err)
			return
		}
		writeJSON(writer, http.StatusOK, map[string]string{"status": "saved"})
	default:
		writer.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func writeJSON(writer http.ResponseWriter, statusCode int, payload any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(statusCode)
	_ = json.NewEncoder(writer).Encode(payload)
}

func writeError(writer http.ResponseWriter, statusCode int, err error) {
	writeJSON(writer, statusCode, map[string]string{
		"error": err.Error(),
	})
}

func (s *Server) String() string {
	return fmt.Sprintf("nestd(unix=%s)", s.app.Paths.SocketPath)
}
