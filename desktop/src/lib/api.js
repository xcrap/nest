const request = (method, route, body) => window.nestAPI.request(method, route, body);

export const api = {
  getSites: () => request("GET", "/sites"),
  createSite: (payload) => request("POST", "/sites", payload),
  updateSite: (id, payload) => request("PATCH", `/sites/${id}`, payload),
  deleteSite: (id) => request("DELETE", `/sites/${id}`),
  startSite: (id) => request("POST", `/sites/${id}/start`),
  stopSite: (id) => request("POST", `/sites/${id}/stop`),
  getLogs: () => request("GET", "/logs/frankenphp"),
  clearLogs: () => request("DELETE", "/logs/frankenphp"),
  getPHPVersions: () => request("GET", "/php/versions"),
  installPHP: (version) => request("POST", "/php/versions/install", { version }),
  activatePHP: (version) => request("POST", "/php/versions/activate", { version }),
  getComposer: () => request("GET", "/composer"),
  checkComposerUpdates: () => request("GET", "/composer/check-updates"),
  installComposer: () => request("POST", "/composer/install"),
  updateComposer: () => request("POST", "/composer/update"),
  rollbackComposer: () => request("POST", "/composer/rollback"),
  getMariaDB: () => request("GET", "/mariadb"),
  checkMariaDBUpdates: () => request("GET", "/mariadb/check-updates"),
  installMariaDB: () => request("POST", "/mariadb/install"),
  startMariaDB: () => request("POST", "/mariadb/start"),
  stopMariaDB: () => request("POST", "/mariadb/stop"),
  getDoctor: () => request("GET", "/doctor"),
  bootstrapTestDomain: () => request("POST", "/bootstrap/test-domain"),
  unbootstrapTestDomain: () => request("POST", "/bootstrap/test-domain/uninstall"),
  trustLocalCA: () => request("POST", "/bootstrap/trust-local-ca"),
  untrustLocalCA: () => request("POST", "/bootstrap/trust-local-ca/uninstall"),
  startServices: () => request("POST", "/services/start"),
  stopServices: () => request("POST", "/services/stop"),
  reloadServices: () => request("POST", "/services/reload"),
  getSettings: () => request("GET", "/settings"),
  getServiceStatus: () => request("GET", "/services/status"),
  fixDoctorCheck: (id) => request("POST", "/doctor/fix", { id }),
  getConfigFiles: () => request("GET", "/config/files"),
  saveConfigFile: (name, content) => request("PUT", `/config/files/${name}`, { content })
};

export const desktop = {
  pickDirectory: () => window.nestDesktop?.pickDirectory?.() ?? Promise.resolve(null),
  exportSites: () => window.nestDesktop?.exportSites?.() ?? Promise.resolve({ exported: false }),
  importSites: () => window.nestDesktop?.importSites?.() ?? Promise.resolve({ imported: false }),
  getMeta: () => window.nestDesktop?.getMeta?.() ?? Promise.resolve({ version: "dev", packaged: false }),
  checkForUpdates: () =>
    window.nestDesktop?.checkForUpdates?.() ??
    Promise.resolve({ status: "current" }),
  installUpdate: () => window.nestDesktop?.installUpdate?.() ?? Promise.resolve(),
  onUpdateStatus: (callback) => window.nestDesktop?.onUpdateStatus?.(callback) ?? (() => {}),
  openExternal: (url) => window.nestDesktop?.openExternal?.(url) ?? Promise.resolve(false)
};
