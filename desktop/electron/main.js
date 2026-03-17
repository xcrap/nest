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
const launchAgentLabel = "dev.nest.nestd";
const launchAgentPath = path.join(os.homedir(), "Library", "LaunchAgents", `${launchAgentLabel}.plist`);
const launchAgentDomain = `gui/${process.getuid()}`;
const launchAgentTarget = `${launchAgentDomain}/${launchAgentLabel}`;
const dnsPort = 5354;
const socketPath = process.env.NEST_SOCKET || path.join(os.homedir(), "Library", "Application Support", "Nest", "run", "nest.sock");
const helperPath = process.env.NEST_HELPER_BIN || resolveBundledBinary("nesthelper");
const daemonPath = process.env.NEST_DAEMON_BIN || resolveBundledBinary("nestd");
const rendererEntryPath = path.join(__dirname, "..", "dist", "index.html");
const hasSingleInstanceLock = app.requestSingleInstanceLock();

let mainWindow = null;
let daemonStartPromise = null;
let bundledDaemonMetaPromise = null;
let lastDaemonStartupError = null;

if (!hasSingleInstanceLock) {
  app.quit();
} else {
  app.on("second-instance", () => {
    void restoreOrCreateWindow();
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

    await createWindow();
    void ensureDaemonAvailable().catch(() => null);
  });
}

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  void restoreOrCreateWindow();
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
      try {
        await ensureDaemonAvailable();
      } catch (error) {
        throw normalizeDaemonRequestError(error);
      }
    }

    try {
      return await performDaemonRequest({ method, route, payload });
    } catch (error) {
      lastError = error;
      if (attempt === 0 && shouldRetryDaemonRequest(error)) {
        try {
          await ensureDaemonAvailable();
        } catch (startError) {
          throw normalizeDaemonRequestError(startError);
        }
        continue;
      }
      throw normalizeDaemonRequestError(error);
    }
  }

  throw normalizeDaemonRequestError(lastError ?? new Error("Nest daemon request failed"));
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
  if (mainWindow && !mainWindow.isDestroyed()) {
    return mainWindow;
  }

  const window = new BrowserWindow({
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
  mainWindow = window;

  window.on("closed", () => {
    if (mainWindow === window) {
      mainWindow = null;
    }
  });

  window.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
    if (process.env.NEST_DEBUG === "1") {
      console.error("[nest] did-fail-load", { errorCode, errorDescription, validatedURL, isMainFrame });
    }
    if (!isMainFrame || window.isDestroyed()) {
      return;
    }
    void loadRecoveryContent(window, `Nest failed to load its interface (${errorDescription || errorCode}). Close and reopen the app.`);
  });

  window.webContents.on("render-process-gone", (_event, details) => {
    if (process.env.NEST_DEBUG === "1") {
      console.error("[nest] render-process-gone", details);
    }
    if (window.isDestroyed()) {
      return;
    }
    if (mainWindow === window) {
      mainWindow = null;
    }
    window.destroy();
    void createWindow();
  });

  if (process.env.NEST_DEBUG === "1") {
    window.webContents.on("console-message", (_event, level, message, line, sourceId) => {
      console.error("[nest] console-message", { level, message, line, sourceId });
    });
  }

  await loadRenderer(window);

  if (process.env.NEST_DEBUG === "1") {
    window.webContents.openDevTools({ mode: "detach" });
  }

  return window;
}

async function restoreOrCreateWindow() {
  const window = mainWindow && !mainWindow.isDestroyed()
    ? mainWindow
    : BrowserWindow.getAllWindows()[0];

  if (!window) {
    await createWindow();
    return;
  }

  mainWindow = window;
  if (window.isMinimized()) {
    window.restore();
  }
  if (!window.isVisible()) {
    window.show();
  }
  if (window.webContents.isCrashed()) {
    await loadRenderer(window).catch(() =>
      loadRecoveryContent(window, "Nest recovered from a renderer crash. Retry the last action.")
    );
  }
  window.focus();
}

async function loadRenderer(window) {
  if (isDev) {
    await window.loadURL(process.env.VITE_DEV_SERVER_URL);
    return;
  }

  await window.loadFile(rendererEntryPath);
}

async function loadRecoveryContent(window, message) {
  if (window.isDestroyed()) {
    return;
  }

  const html = `<!doctype html>
<html lang="en">
  <body style="margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f5f5f4;color:#18181b;">
    <main style="display:flex;min-height:100vh;align-items:center;justify-content:center;padding:32px;">
      <section style="max-width:560px;border:1px solid #e4e4e7;background:#fff;border-radius:24px;padding:32px;box-shadow:0 18px 50px -40px rgba(24,24,27,0.35);">
        <p style="margin:0 0 8px;font-size:12px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#dc2626;">Nest Error</p>
        <h1 style="margin:0 0 12px;font-size:28px;line-height:1.2;">Nest couldn't render its interface.</h1>
        <p style="margin:0;font-size:15px;line-height:1.6;color:#52525b;">${escapeHTML(message)}</p>
      </section>
    </main>
  </body>
</html>`;

  await window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html)}`);
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

function normalizeDaemonRequestError(error) {
  const message = String(error?.message || error || "").trim();
  if (!message) {
    return new Error("Nest request failed.");
  }
  if (message.includes("Nest couldn't start its background daemon")) {
    return new Error(message);
  }
  if (message.includes("Nest daemon did not become ready")) {
    return new Error("Nest couldn't start its background daemon. PHP, Composer, MariaDB, site actions, and bootstrap stay unavailable until that is fixed.");
  }
  if (lastDaemonStartupError?.message && message.includes("connect: no such file or directory")) {
    return new Error(lastDaemonStartupError.message);
  }
  return error instanceof Error ? error : new Error(message);
}

async function ensureDaemonStarted() {
  if (!fs.existsSync(daemonPath)) {
    throw new Error(`Nest daemon binary not found at ${daemonPath}. Build it with 'make build' before launching the desktop app.`);
  }

  ensureLaunchAgentConfig();
  const alive = fs.existsSync(socketPath) ? await pingDaemon().catch(() => false) : false;
  const compatible = alive ? await daemonMatchesCurrentBundle().catch(() => false) : false;

  if (alive && compatible) {
    lastDaemonStartupError = null;
    return;
  }

  if (alive && !compatible) {
    await stopConflictingDaemon();
  }

  await restartLaunchAgent();

  try {
    await waitForDaemonReady(5000);
    lastDaemonStartupError = null;
  } catch (error) {
    const stoppedConflict = await stopConflictingDaemon().catch(() => false);
    if (stoppedConflict) {
      await restartLaunchAgent();
      await waitForDaemonReady(5000);
      lastDaemonStartupError = null;
      return;
    }

    lastDaemonStartupError = await formatDaemonStartupError(error);
    throw lastDaemonStartupError;
  }
}

async function formatDaemonStartupError(error) {
  const conflict = await describeUDPPortOwner(dnsPort);
  if (conflict?.path) {
    if (path.basename(conflict.path) === "nestd" && !sameRealPath(conflict.path, daemonPath)) {
      return new Error(`Nest couldn't start its background daemon because another Nest build is already running (${conflict.path}). Quit the older Nest app and retry.`);
    }
    if (path.basename(conflict.path) !== "nestd") {
      return new Error(`Nest couldn't start its background daemon because UDP port ${dnsPort} is already in use by ${conflict.path}.`);
    }
  }

  const message = String(error?.message || error || "").trim();
  if (message.includes("Nest daemon did not become ready")) {
    return new Error("Nest couldn't start its background daemon. Check ~/Library/Application Support/Nest/logs/nestd.log and retry.");
  }

  return error instanceof Error ? error : new Error(message || "Nest daemon failed to start.");
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

function pidForUDPPort(port) {
  return new Promise((resolve) => {
    execFile("lsof", ["-nP", "-t", `-iUDP:${port}`], (error, stdout) => {
      if (error) {
        resolve(null);
        return;
      }
      const pid = Number.parseInt(String(stdout).trim().split("\n")[0], 10);
      resolve(Number.isFinite(pid) ? pid : null);
    });
  });
}

async function describeUDPPortOwner(port) {
  const pid = await pidForUDPPort(port);
  if (!pid) {
    return null;
  }

  const actualPath = await executablePathForPid(pid);
  return {
    pid,
    path: actualPath || `pid ${pid}`
  };
}

async function stopConflictingDaemon() {
  const candidatePIDs = new Set();
  const socketPID = await pidForSocket(socketPath);
  if (socketPID) {
    candidatePIDs.add(socketPID);
  }
  const udpPID = await pidForUDPPort(dnsPort);
  if (udpPID) {
    candidatePIDs.add(udpPID);
  }

  let stopped = false;
  for (const pid of candidatePIDs) {
    if (await terminateConflictingDaemon(pid)) {
      stopped = true;
    }
  }

  return stopped;
}

async function terminateConflictingDaemon(pid) {
  const actualPath = await executablePathForPid(pid);
  if (!actualPath || path.basename(actualPath) !== "nestd") {
    return false;
  }
  if (sameRealPath(actualPath, daemonPath)) {
    return false;
  }

  await terminatePID(pid);
  return true;
}

function terminatePID(pid) {
  return new Promise((resolve, reject) => {
    try {
      process.kill(pid, "SIGTERM");
    } catch (error) {
      if (error.code === "ESRCH") {
        resolve(false);
        return;
      }
      reject(error);
      return;
    }

    const softDeadline = Date.now() + 3000;
    const hardDeadline = Date.now() + 6000;
    let escalated = false;

    const timer = setInterval(() => {
      try {
        process.kill(pid, 0);

        if (!escalated && Date.now() >= softDeadline) {
          escalated = true;
          process.kill(pid, "SIGKILL");
        }

        if (Date.now() >= hardDeadline) {
          clearInterval(timer);
          reject(new Error(`Timed out waiting for daemon process ${pid} to exit`));
        }
      } catch (error) {
        clearInterval(timer);
        if (error.code === "ESRCH") {
          resolve(true);
          return;
        }
        reject(error);
      }
    }, 100);
  });
}

function sameRealPath(left, right) {
  try {
    return fs.realpathSync(left) === fs.realpathSync(right);
  } catch {
    return path.resolve(left) === path.resolve(right);
  }
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

function escapeHTML(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
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
