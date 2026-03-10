const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("nestAPI", {
  request: (method, route, body) => ipcRenderer.invoke("daemon:request", { method, route, body })
});
