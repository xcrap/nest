const { contextBridge, ipcRenderer } = require("electron");

const normalizeIPCError = (error) => {
  const message = String(error?.message || error || "")
    .replace(/^Error invoking remote method '[^']+':\s*/, "")
    .trim();
  return new Error(message || "Nest request failed.");
};

const invoke = async (channel, ...args) => {
  try {
    return await ipcRenderer.invoke(channel, ...args);
  } catch (error) {
    throw normalizeIPCError(error);
  }
};

contextBridge.exposeInMainWorld("nestAPI", {
  request: (method, route, body) => invoke("daemon:request", { method, route, body })
});

contextBridge.exposeInMainWorld("nestDesktop", {
  pickDirectory: () => invoke("dialog:pick-directory"),
  exportSites: () => invoke("dialog:export-sites"),
  importSites: () => invoke("dialog:import-sites"),
  getMeta: () => invoke("app:get-meta"),
  checkForUpdates: () => invoke("updates:check"),
  installUpdate: () => invoke("updates:install"),
  onUpdateStatus: (callback) => {
    const handler = (_event, data) => callback(data);
    ipcRenderer.on("update:status", handler);
    return () => ipcRenderer.removeListener("update:status", handler);
  },
  openExternal: (url) => invoke("shell:open-external", url)
});
