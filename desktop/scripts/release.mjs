import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const desktopDir = path.resolve(__dirname, "..");
const packageJson = JSON.parse(fs.readFileSync(path.join(desktopDir, "package.json"), "utf8"));
const arch = process.arch;
const releaseDir = path.join(desktopDir, "release");
const appPath = path.join(releaseDir, `mac-${arch}`, "Nest.app");
const dmgPath = path.join(releaseDir, `Nest-${packageJson.version}-${arch}.dmg`);

if (process.platform !== "darwin") {
  throw new Error("Nest release builds currently require macOS because DMG creation uses hdiutil.");
}

run("npm", ["run", "build"]);
run("npm", ["exec", "electron-builder", "--", "--mac", "dir", "zip", "--publish", "never"]);

if (!fs.existsSync(appPath)) {
  throw new Error(`Expected packaged app at ${appPath}`);
}

if (fs.existsSync(dmgPath)) {
  fs.rmSync(dmgPath, { force: true });
}

run("hdiutil", ["create", "-volname", "Nest", "-srcfolder", appPath, "-ov", "-format", "UDZO", dmgPath]);

function run(command, args) {
  execFileSync(command, args, {
    cwd: desktopDir,
    stdio: "inherit"
  });
}
