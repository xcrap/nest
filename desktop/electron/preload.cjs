const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("nestAPI", {
  request: (method, route, body) => ipcRenderer.invoke("daemon:request", { method, route, body })
});

contextBridge.exposeInMainWorld("nestDesktop", {
  pickDirectory: () => ipcRenderer.invoke("dialog:pick-directory"),
  exportSites: () => ipcRenderer.invoke("dialog:export-sites"),
  importSites: () => ipcRenderer.invoke("dialog:import-sites"),
  getMeta: () => ipcRenderer.invoke("app:get-meta"),
  checkForUpdates: () => ipcRenderer.invoke("updates:check"),
  installUpdate: () => ipcRenderer.invoke("updates:install"),
  onUpdateStatus: (callback) => {
    const handler = (_event, data) => callback(data);
    ipcRenderer.on("update:status", handler);
    return () => ipcRenderer.removeListener("update:status", handler);
  },
  openExternal: (url) => ipcRenderer.invoke("shell:open-external", url)
});
