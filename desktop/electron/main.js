import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
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
  ipcMain.handle("dialog:pick-directory", handlePickDirectory);
  ipcMain.handle("app:get-meta", () => getAppMeta());
  ipcMain.handle("updates:check", checkForUpdates);
  ipcMain.handle("shell:open-external", async (_event, url) => shell.openExternal(url));

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
    width: 1520,
    height: 980,
    minWidth: 1240,
    minHeight: 780,
    backgroundColor: "#fafafa",
    titleBarStyle: "hiddenInset",
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

function handlePickDirectory() {
  return dialog
    .showOpenDialog(mainWindow, {
      properties: ["openDirectory", "createDirectory"],
      buttonLabel: "Choose folder"
    })
    .then((result) => (result.canceled ? null : result.filePaths[0]));
}

function getAppMeta() {
  return {
    version: app.getVersion(),
    packaged: app.isPackaged,
    platform: process.platform,
    arch: process.arch,
    releaseFeedConfigured: Boolean(resolveReleaseRepository())
  };
}

async function checkForUpdates() {
  const repository = resolveReleaseRepository();
  if (!repository) {
    return {
      configured: false,
      status: "unavailable",
      message: "Set NEST_GITHUB_REPOSITORY to enable GitHub release checks for this build."
    };
  }

  const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "Nest"
    }
  });
  if (!response.ok) {
    throw new Error(`Release check failed with ${response.status}`);
  }

  const release = await response.json();
  const latestVersion = normalizeVersion(release.tag_name || release.name || app.getVersion());
  const currentVersion = normalizeVersion(app.getVersion());
  const asset = pickReleaseAsset(release.assets || []);

  return {
    configured: true,
    status: compareVersions(latestVersion, currentVersion) > 0 ? "available" : "current",
    currentVersion,
    latestVersion,
    publishedAt: release.published_at,
    notes: release.body || "",
    htmlUrl: release.html_url,
    asset: asset
      ? {
          name: asset.name,
          url: asset.browser_download_url
        }
      : null
  };
}

function resolveReleaseRepository() {
  return process.env.NEST_GITHUB_REPOSITORY || "xcrap/nest";
}

function pickReleaseAsset(assets) {
  const lowerArch = process.arch.toLowerCase();
  const candidates = assets.filter((asset) => /\.(dmg|zip)$/i.test(asset.name || ""));
  if (candidates.length === 0) {
    return null;
  }

  return (
    candidates.find((asset) => asset.name.toLowerCase().includes(lowerArch) && asset.name.toLowerCase().endsWith(".dmg")) ||
    candidates.find((asset) => asset.name.toLowerCase().endsWith(".dmg")) ||
    candidates.find((asset) => asset.name.toLowerCase().includes(lowerArch)) ||
    candidates[0]
  );
}

function normalizeVersion(value) {
  return String(value || "0.0.0").replace(/^v/, "");
}

function compareVersions(leftVersion, rightVersion) {
  const left = normalizeVersion(leftVersion).split(".").map((part) => Number.parseInt(part, 10) || 0);
  const right = normalizeVersion(rightVersion).split(".").map((part) => Number.parseInt(part, 10) || 0);
  const length = Math.max(left.length, right.length);

  for (let index = 0; index < length; index += 1) {
    const diff = (left[index] || 0) - (right[index] || 0);
    if (diff !== 0) {
      return diff;
    }
  }

  return 0;
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
