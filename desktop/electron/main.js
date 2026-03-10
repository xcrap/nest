import { app, BrowserWindow, ipcMain } from "electron";
import { execFile } from "node:child_process";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
const socketPath = process.env.NEST_SOCKET || path.join(os.homedir(), "Library", "Application Support", "Nest", "run", "nest.sock");
const helperPath = process.env.NEST_HELPER_BIN || resolveBundledBinary("nesthelper");
const daemonPath = process.env.NEST_DAEMON_BIN || resolveBundledBinary("nestd");

let mainWindow;
let daemonProcess;

app.whenReady().then(async () => {
  ipcMain.handle("daemon:request", async (_event, request) => requestDaemon(request));
  await ensureDaemonStarted();
  await createWindow();
});

app.on("window-all-closed", () => {
  if (daemonProcess && !daemonProcess.killed) {
    daemonProcess.kill("SIGTERM");
  }
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    app.whenReady().then(() => createWindow());
  }
});

async function requestDaemon({ method, route, body }) {
  if (route === "/bootstrap/test-domain" && method === "POST") {
    await runPrivilegedHelper("bootstrap", "test-domain");
    return requestDaemon({ method: "POST", route: "/bootstrap/test-domain?skipHelper=1" });
  }
  if (route === "/bootstrap/trust-local-ca" && method === "POST") {
    await runPrivilegedHelper("trust", "local-ca");
    return requestDaemon({ method: "POST", route: "/bootstrap/trust-local-ca?skipHelper=1" });
  }

  if (!fs.existsSync(socketPath)) {
    throw new Error(`Nest daemon socket not found at ${socketPath}. Start nestd first.`);
  }

  const payload = body ? JSON.stringify(body) : null;

  return new Promise((resolve, reject) => {
    const request = http.request(
      {
        method,
        socketPath,
        path: route,
        headers: payload
          ? {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(payload)
            }
          : undefined
      },
      (response) => {
        let data = "";
        response.on("data", (chunk) => {
          data += chunk;
        });
        response.on("end", () => {
          const parsed = data ? JSON.parse(data) : null;
          if (response.statusCode >= 400) {
            reject(new Error(parsed?.error || `Daemon request failed with ${response.statusCode}`));
            return;
          }
          resolve(parsed);
        });
      }
    );

    request.on("error", reject);
    if (payload) {
      request.write(payload);
    }
    request.end();
  });
}

async function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1120,
    minHeight: 720,
    backgroundColor: "#f4efe4",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  if (process.env.NEST_DEBUG === "1") {
    mainWindow.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL) => {
      console.error("[nest] did-fail-load", { errorCode, errorDescription, validatedURL });
    });
    mainWindow.webContents.on("console-message", (_event, level, message, line, sourceId) => {
      console.error("[nest] console-message", { level, message, line, sourceId });
    });
    mainWindow.webContents.on("render-process-gone", (_event, details) => {
      console.error("[nest] render-process-gone", details);
    });
    mainWindow.webContents.on("did-finish-load", () => {
      console.error("[nest] did-finish-load", mainWindow.webContents.getURL());
      setTimeout(async () => {
        try {
          const snapshot = await mainWindow.webContents.executeJavaScript(`
            ({
              hasNestAPI: typeof window.nestAPI !== "undefined",
              bodyText: document.body.innerText.slice(0, 200),
              rootHTML: document.getElementById("root")?.innerHTML.slice(0, 500) || "",
              documentHTML: document.documentElement.outerHTML.slice(0, 500)
            })
          `);
          console.error("[nest] renderer-snapshot", snapshot);
        } catch (error) {
          console.error("[nest] renderer-snapshot-error", error);
        }
      }, 1000);
    });
  }

  if (isDev) {
    await mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    await mainWindow.loadFile(path.join(__dirname, "..", "dist", "index.html"));
  }

  if (process.env.NEST_DEBUG === "1") {
    mainWindow.webContents.openDevTools({ mode: "detach" });
  }
}

function runPrivilegedHelper(...args) {
  const shellCommand = [helperPath, ...args].map(shellQuote).join(" ");
  const script = `do shell script ${appleScriptQuote(shellCommand)} with administrator privileges`;

  return new Promise((resolve, reject) => {
    execFile("osascript", ["-e", script], (error, stdout, stderr) => {
      if (error) {
        reject(new Error((stderr || stdout || error.message).trim()));
        return;
      }
      resolve();
    });
  });
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function appleScriptQuote(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

async function ensureDaemonStarted() {
  if (fs.existsSync(socketPath)) {
    return;
  }
  if (!fs.existsSync(daemonPath)) {
    throw new Error(`Nest daemon binary not found at ${daemonPath}. Build it with 'make build' before launching the desktop app.`);
  }

  daemonProcess = spawn(daemonPath, [], {
    stdio: "ignore",
    detached: false
  });

  daemonProcess.on("exit", () => {
    daemonProcess = null;
  });

  await waitForSocket(socketPath, 5000);
}

function resolveBundledBinary(name) {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "bin", name);
  }
  return path.join(__dirname, "..", "..", "bin", name);
}

function waitForSocket(targetPath, timeoutMs) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const timer = setInterval(() => {
      if (fs.existsSync(targetPath)) {
        clearInterval(timer);
        resolve();
        return;
      }
      if (Date.now() - startedAt > timeoutMs) {
        clearInterval(timer);
        reject(new Error(`Nest daemon did not create its socket at ${targetPath}`));
      }
    }, 100);
  });
}
