import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, "..");
const workspaceRoot = path.resolve(rootDir, "..");
const viteBin = resolveBin("vite");
const electronBin = resolveBin("electron");
let shuttingDown = false;

const vite = spawn(viteBin, ["--host", "127.0.0.1", "--port", "5173"], {
  cwd: rootDir,
  stdio: "inherit"
});

let electron;
const stop = () => {
  shuttingDown = true;
  vite.kill("SIGTERM");
  if (electron) {
    electron.kill("SIGTERM");
  } else {
    process.exit(0);
  }
};

process.on("SIGINT", stop);
process.on("SIGTERM", stop);

await waitForServer("http://127.0.0.1:5173");

electron = spawn(electronBin, ["."], {
  cwd: rootDir,
  stdio: "inherit",
  env: {
    ...process.env,
    VITE_DEV_SERVER_URL: "http://127.0.0.1:5173"
  }
});

electron.on("exit", (code) => {
  vite.kill("SIGTERM");
  process.exit(shuttingDown ? 0 : (code ?? 0));
});

function waitForServer(url) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const timer = setInterval(() => {
      http.get(url, (response) => {
        response.resume();
        clearInterval(timer);
        resolve();
      }).on("error", () => {
        if (Date.now() - startedAt > 20000) {
          clearInterval(timer);
          reject(new Error("vite dev server did not start in time"));
        }
      });
    }, 250);
  });
}

function resolveBin(name) {
  const candidates = [
    path.join(rootDir, "node_modules", ".bin", name),
    path.join(workspaceRoot, "node_modules", ".bin", name)
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(`Unable to find ${name} in workspace or repo root node_modules/.bin`);
}
