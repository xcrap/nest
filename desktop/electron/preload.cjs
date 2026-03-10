const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("nestAPI", {
  request: (method, route, body) => ipcRenderer.invoke("daemon:request", { method, route, body })
});

contextBridge.exposeInMainWorld("nestDesktop", {
  pickDirectory: () => ipcRenderer.invoke("dialog:pick-directory"),
  getMeta: () => ipcRenderer.invoke("app:get-meta"),
  checkForUpdates: () => ipcRenderer.invoke("updates:check"),
  openExternal: (url) => ipcRenderer.invoke("shell:open-external", url)
});
