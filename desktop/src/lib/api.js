const request = (method, route, body) => window.nestAPI.request(method, route, body);

export const api = {
  getSites: () => request("GET", "/sites"),
  createSite: (payload) => request("POST", "/sites", payload),
  updateSite: (id, payload) => request("PATCH", `/sites/${id}`, payload),
  deleteSite: (id) => request("DELETE", `/sites/${id}`),
  startSite: (id) => request("POST", `/sites/${id}/start`),
  stopSite: (id) => request("POST", `/sites/${id}/stop`),
  getLogs: () => request("GET", "/logs/frankenphp"),
  getPHPVersions: () => request("GET", "/php/versions"),
  installPHP: (version) => request("POST", "/php/versions/install", { version }),
  activatePHP: (version) => request("POST", "/php/versions/activate", { version }),
  getDoctor: () => request("GET", "/doctor"),
  bootstrapTestDomain: () => request("POST", "/bootstrap/test-domain"),
  trustLocalCA: () => request("POST", "/bootstrap/trust-local-ca"),
  startServices: () => request("POST", "/services/start"),
  stopServices: () => request("POST", "/services/stop"),
  reloadServices: () => request("POST", "/services/reload"),
  getServiceStatus: () => request("GET", "/services/status")
};

export const desktop = {
  pickDirectory: () => window.nestDesktop?.pickDirectory?.() ?? Promise.resolve(null),
  getMeta: () => window.nestDesktop?.getMeta?.() ?? Promise.resolve({ version: "dev", packaged: false }),
  checkForUpdates: () =>
    window.nestDesktop?.checkForUpdates?.() ??
    Promise.resolve({
      configured: false,
      status: "unavailable",
      message: "Release feed is not configured for this build."
    }),
  openExternal: (url) => window.nestDesktop?.openExternal?.(url) ?? Promise.resolve(false)
};
