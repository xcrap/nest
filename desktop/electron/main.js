import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import electronUpdater from "electron-updater";
const { autoUpdater } = electronUpdater;
import { execFile } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
const launchAgentLabel = "dev.xcrap.nestd";
const launchAgentPath = path.join(os.homedir(), "Library", "LaunchAgents", `${launchAgentLabel}.plist`);
const launchAgentDomain = `gui/${process.getuid()}`;
const launchAgentTarget = `${launchAgentDomain}/${launchAgentLabel}`;
const socketPath = process.env.NEST_SOCKET || path.join(os.homedir(), "Library", "Application Support", "Nest", "run", "nest.sock");
const helperPath = process.env.NEST_HELPER_BIN || resolveBundledBinary("nesthelper");
const daemonPath = process.env.NEST_DAEMON_BIN || resolveBundledBinary("nestd");
const hasSingleInstanceLock = app.requestSingleInstanceLock();

let mainWindow;
let daemonStartPromise = null;
let bundledDaemonMetaPromise = null;

if (!hasSingleInstanceLock) {
  app.quit();
} else {
  app.on("second-instance", () => {
    if (!mainWindow) {
      return;
    }
    if (mainWindow.isMinimized()) {
      mainWindow.restore();
    }
    mainWindow.focus();
  });

  app.whenReady().then(async () => {
    ipcMain.handle("daemon:request", async (_event, request) => requestDaemon(request));
    ipcMain.handle("dialog:pick-directory", handlePickDirectory);
    ipcMain.handle("dialog:export-sites", handleExportSites);
    ipcMain.handle("dialog:import-sites", handleImportSites);
    ipcMain.handle("app:get-meta", () => getAppMeta());
    ipcMain.handle("updates:check", handleCheckForUpdates);
    ipcMain.handle("updates:install", () => autoUpdater.quitAndInstall());
    ipcMain.handle("shell:open-external", async (_event, url) => shell.openExternal(url));

    setupAutoUpdater();

    await ensureDaemonStarted();
    await createWindow();
  });
}

app.on("window-all-closed", () => {
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
  if (route === "/bootstrap/test-domain/uninstall" && method === "POST") {
    await runPrivilegedHelper("unbootstrap", "test-domain");
    return requestDaemon({ method: "POST", route: "/bootstrap/test-domain/uninstall?skipHelper=1" });
  }
  if (route === "/bootstrap/trust-local-ca" && method === "POST") {
    await runPrivilegedHelper("trust", "local-ca");
    return requestDaemon({ method: "POST", route: "/bootstrap/trust-local-ca?skipHelper=1" });
  }
  if (route === "/bootstrap/trust-local-ca/uninstall" && method === "POST") {
    await runPrivilegedHelper("untrust", "local-ca");
    return requestDaemon({ method: "POST", route: "/bootstrap/trust-local-ca/uninstall?skipHelper=1" });
  }

  const payload = body ? JSON.stringify(body) : null;
  let lastError = null;

  for (let attempt = 0; attempt < 2; attempt += 1) {
    if (!fs.existsSync(socketPath)) {
      await ensureDaemonAvailable();
    }

    try {
      return await performDaemonRequest({ method, route, payload });
    } catch (error) {
      lastError = error;
      if (attempt === 0 && shouldRetryDaemonRequest(error)) {
        await ensureDaemonAvailable();
        continue;
      }
      throw error;
    }
  }

  throw lastError ?? new Error("Nest daemon request failed");
}

function performDaemonRequest({ method, route, payload }) {
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
          let parsed = null;
          try {
            parsed = data ? JSON.parse(data) : null;
          } catch {
            reject(new Error(data?.trim() || `Daemon returned invalid response (${response.statusCode})`));
            return;
          }
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

function shouldRetryDaemonRequest(error) {
  if (!error) {
    return false;
  }

  return (
    ["ENOENT", "ECONNREFUSED", "ECONNRESET", "EPIPE"].includes(error.code) ||
    /socket not found|socket hang up|connect: no such file or directory|ECONN/i.test(String(error.message || ""))
  );
}

function ensureDaemonAvailable() {
  if (!daemonStartPromise) {
    daemonStartPromise = ensureDaemonStarted().finally(() => {
      daemonStartPromise = null;
    });
  }
  return daemonStartPromise;
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

async function handleExportSites() {
  const sitesData = await requestDaemon({ method: "GET", route: "/sites" });
  const exportPayload = {
    version: 1,
    exportedAt: new Date().toISOString(),
    sites: sitesData.map(({ name, domain, rootPath, documentRoot }) => ({
      name,
      domain,
      rootPath,
      documentRoot
    }))
  };

  const result = await dialog.showSaveDialog(mainWindow, {
    title: "Export sites",
    defaultPath: path.join(os.homedir(), "nest-sites.json"),
    filters: [{ name: "JSON", extensions: ["json"] }]
  });

  if (result.canceled) {
    return { exported: false };
  }

  fs.writeFileSync(result.filePath, JSON.stringify(exportPayload, null, 2), "utf-8");
  return { exported: true, count: exportPayload.sites.length, path: result.filePath };
}

async function handleImportSites() {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "Import sites",
    filters: [{ name: "JSON", extensions: ["json"] }],
    properties: ["openFile"]
  });

  if (result.canceled) {
    return { imported: false };
  }

  const raw = fs.readFileSync(result.filePaths[0], "utf-8");
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("The selected file is not valid JSON.");
  }

  const sites = Array.isArray(parsed) ? parsed : parsed.sites;
  if (!Array.isArray(sites)) {
    throw new Error("The selected file does not contain a valid sites array.");
  }

  const importResult = await requestDaemon({ method: "POST", route: "/sites/import", body: sites });
  return { imported: true, ...importResult };
}

function getAppMeta() {
  return {
    version: app.getVersion(),
    packaged: app.isPackaged,
    platform: process.platform,
    arch: process.arch,
    releaseFeedConfigured: app.isPackaged
  };
}

function setupAutoUpdater() {
  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = false;

  autoUpdater.on("update-available", (info) => {
    mainWindow?.webContents.send("update:status", {
      status: "available",
      version: info.version,
      releaseDate: info.releaseDate
    });
  });

  autoUpdater.on("update-not-available", (info) => {
    mainWindow?.webContents.send("update:status", {
      status: "current",
      version: info.version
    });
  });

  autoUpdater.on("download-progress", (progress) => {
    mainWindow?.webContents.send("update:status", {
      status: "downloading",
      percent: Math.round(progress.percent)
    });
  });

  autoUpdater.on("update-downloaded", (info) => {
    mainWindow?.webContents.send("update:status", {
      status: "ready",
      version: info.version
    });
  });

  autoUpdater.on("error", (error) => {
    mainWindow?.webContents.send("update:status", {
      status: "error",
      message: error?.message || "Update check failed."
    });
  });
}

async function handleCheckForUpdates() {
  if (isDev) {
    return { status: "current", version: app.getVersion() };
  }

  const result = await autoUpdater.checkForUpdates();
  if (!result) {
    return { status: "current", version: app.getVersion() };
  }

  const updateAvailable = result.updateInfo && autoUpdater.currentVersion.compare(result.updateInfo.version) < 0;

  if (updateAvailable) {
    // Don't await — let download-progress and update-downloaded events drive the UI
    autoUpdater.downloadUpdate();
    return null;
  }

  return { status: "current", version: app.getVersion() };
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
  if (!fs.existsSync(daemonPath)) {
    throw new Error(`Nest daemon binary not found at ${daemonPath}. Build it with 'make build' before launching the desktop app.`);
  }

  const agentChanged = ensureLaunchAgentConfig();
  const alive = fs.existsSync(socketPath) ? await pingDaemon().catch(() => false) : false;
  const compatible = alive ? await daemonMatchesCurrentBundle().catch(() => false) : false;

  if (agentChanged || !alive || !compatible) {
    await restartLaunchAgent();
  }

  await waitForDaemonReady(5000);
}

async function daemonUsesExpectedBinary() {
  const pid = await pidForSocket(socketPath);
  if (!pid) {
    return false;
  }

  const actualPath = await executablePathForPid(pid);
  if (!actualPath) {
    return false;
  }

  try {
    return fs.realpathSync(actualPath) === fs.realpathSync(daemonPath);
  } catch {
    return actualPath === daemonPath;
  }
}

async function daemonMatchesCurrentBundle() {
  const [runningMeta, bundledMeta, expectedBinary] = await Promise.all([
    fetchDaemonMeta(),
    bundledDaemonMeta(),
    daemonUsesExpectedBinary().catch(() => false)
  ]);

  return (
    Boolean(runningMeta?.version) &&
    Boolean(runningMeta?.buildId) &&
    runningMeta.version === bundledMeta.version &&
    runningMeta.buildId === bundledMeta.buildId &&
    expectedBinary
  );
}

function fetchDaemonMeta() {
  return new Promise((resolve, reject) => {
    const req = http.request({ method: "GET", socketPath, path: "/meta", timeout: 2000 }, (res) => {
      let data = "";
      res.on("data", (chunk) => {
        data += chunk;
      });
      res.on("end", () => {
        if (res.statusCode !== 200) {
          reject(new Error(`Unexpected daemon meta status ${res.statusCode}`));
          return;
        }
        try {
          resolve(JSON.parse(data));
        } catch (error) {
          reject(error);
        }
      });
    });
    req.on("error", reject);
    req.on("timeout", () => { req.destroy(); reject(new Error("Timed out reading daemon metadata")); });
    req.end();
  });
}

function bundledDaemonMeta() {
  if (!bundledDaemonMetaPromise) {
    bundledDaemonMetaPromise = new Promise((resolve, reject) => {
      execFile(daemonPath, ["--meta-json"], (error, stdout, stderr) => {
        if (error) {
          reject(new Error((stderr || stdout || error.message).trim()));
          return;
        }
        try {
          resolve(JSON.parse(stdout));
        } catch (parseError) {
          reject(parseError);
        }
      });
    });
  }
  return bundledDaemonMetaPromise;
}

function pidForSocket(targetPath) {
  return new Promise((resolve) => {
    execFile("lsof", ["-t", "--", targetPath], (error, stdout) => {
      if (error) {
        resolve(null);
        return;
      }
      const pid = Number.parseInt(String(stdout).trim().split("\n")[0], 10);
      resolve(Number.isFinite(pid) ? pid : null);
    });
  });
}

function executablePathForPid(pid) {
  return new Promise((resolve) => {
    execFile("lsof", ["-a", "-p", String(pid), "-d", "txt", "-Fn"], (error, stdout) => {
      if (error) {
        resolve(null);
        return;
      }

      const line = String(stdout)
        .split("\n")
        .find((entry) => entry.startsWith("n/"));

      resolve(line ? line.slice(1) : null);
    });
  });
}

function pingDaemon() {
  return new Promise((resolve, reject) => {
    const req = http.request({ method: "GET", socketPath, path: "/services/status", timeout: 2000 }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode < 500));
    });
    req.on("error", () => reject(false));
    req.on("timeout", () => { req.destroy(); reject(false); });
    req.end();
  });
}

function resolveBundledBinary(name) {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "bin", name);
  }
  return path.join(__dirname, "..", "..", "bin", name);
}

function ensureLaunchAgentConfig() {
  const logsDir = path.join(os.homedir(), "Library", "Application Support", "Nest", "logs");
  fs.mkdirSync(path.dirname(launchAgentPath), { recursive: true });
  fs.mkdirSync(logsDir, { recursive: true });

  const content = renderLaunchAgentPlist(path.join(logsDir, "nestd.log"));
  const current = fs.existsSync(launchAgentPath) ? fs.readFileSync(launchAgentPath, "utf-8") : "";
  if (current === content) {
    return false;
  }

  fs.writeFileSync(launchAgentPath, content, { mode: 0o600 });
  return true;
}

async function restartLaunchAgent() {
  try {
    await runLaunchctl("bootout", launchAgentTarget);
  } catch {}

  try {
    if (fs.existsSync(socketPath)) {
      fs.unlinkSync(socketPath);
    }
  } catch {}

  await runLaunchctl("bootstrap", launchAgentDomain, launchAgentPath);
  await runLaunchctl("enable", launchAgentTarget).catch(() => {});
  await runLaunchctl("kickstart", "-k", launchAgentTarget);
}

function runLaunchctl(...args) {
  return new Promise((resolve, reject) => {
    execFile("launchctl", args, (error, stdout, stderr) => {
      if (error) {
        reject(new Error((stderr || stdout || error.message).trim()));
        return;
      }
      resolve(String(stdout).trim());
    });
  });
}

function renderLaunchAgentPlist(logPath) {
  const environment = [];
  if (process.env.NEST_SOCKET) {
    environment.push(`<key>NEST_SOCKET</key><string>${escapePlist(process.env.NEST_SOCKET)}</string>`);
  }

  const environmentBlock = environment.length > 0
    ? `<key>EnvironmentVariables</key><dict>${environment.join("")}</dict>`
    : "";

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${launchAgentLabel}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escapePlist(daemonPath)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${escapePlist(path.dirname(daemonPath))}</string>
  <key>StandardOutPath</key>
  <string>${escapePlist(logPath)}</string>
  <key>StandardErrorPath</key>
  <string>${escapePlist(logPath)}</string>
  ${environmentBlock}
</dict>
</plist>
`;
}

function escapePlist(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function waitForDaemonReady(timeoutMs) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    let checking = false;
    const timer = setInterval(() => {
      if (checking) {
        return;
      }
      checking = true;

      Promise.resolve()
        .then(async () => {
          if (fs.existsSync(socketPath)) {
            const alive = await pingDaemon().catch(() => false);
            if (alive) {
              clearInterval(timer);
              resolve();
              return;
            }
          }

          if (Date.now() - startedAt > timeoutMs) {
            clearInterval(timer);
            reject(new Error(`Nest daemon did not become ready on ${socketPath}`));
          }
        })
        .finally(() => {
          checking = false;
        });
    }, 100);
  });
}
