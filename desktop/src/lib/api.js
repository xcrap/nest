const request = (method, route, body) => window.nestAPI.request(method, route, body);

export const api = {
  getSites: () => request("GET", "/sites"),
  createSite: (payload) => request("POST", "/sites", payload),
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
