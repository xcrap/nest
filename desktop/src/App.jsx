import { useEffect, useState } from "react";
import { Code2, Database, FileText, Globe2, LayoutDashboard, Play, RefreshCw, RotateCcw, Settings2, SlidersHorizontal, Square } from "lucide-react";

import { Badge } from "./components/ui/badge";
import { Button } from "./components/ui/button";
import { Separator } from "./components/ui/separator";
import { api, desktop } from "./lib/api";
import { cn } from "./lib/utils";
import { DashboardScreen } from "./screens/DashboardScreen";
import { LogsScreen } from "./screens/LogsScreen";
import { MariaDBScreen } from "./screens/MariaDBScreen";
import { PHPVersionsScreen } from "./screens/PHPVersionsScreen";
import { SettingsScreen } from "./screens/SettingsScreen";
import { ConfigScreen } from "./screens/ConfigScreen";
import { SitesScreen } from "./screens/SitesScreen";

const tabs = [
  { value: "dashboard", label: "Dashboard", icon: LayoutDashboard },
  { value: "sites", label: "Sites", icon: Globe2 },
  { value: "config", label: "Config", icon: SlidersHorizontal },
  { value: "logs", label: "Logs", icon: FileText },
  { value: "php", label: "PHP", icon: Code2 },
  { value: "mariadb", label: "MariaDB", icon: Database },
  { value: "settings", label: "Settings", icon: Settings2 }
];

const serviceVariant = {
  running: "success",
  stopped: "warning",
  unknown: "default"
};

export default function App() {
  const [activeTab, setActiveTab] = useState("dashboard");
  const [sites, setSites] = useState([]);
  const [doctorChecks, setDoctorChecks] = useState([]);
  const [logs, setLogs] = useState("");
  const [versions, setVersions] = useState([]);
  const [mariaDB, setMariaDB] = useState(null);
  const [serviceStatus, setServiceStatus] = useState("unknown");
  const [settings, setSettings] = useState(null);
  const [configs, setConfigs] = useState({});
  const [error, setError] = useState("");
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [appMeta, setAppMeta] = useState({
    version: "0.1.0",
    packaged: false,
    platform: "macOS",
    arch: "arm64",
    releaseFeedConfigured: false
  });
  const [updateState, setUpdateState] = useState({ status: "idle" });

  const refresh = async () => {
    try {
      setIsRefreshing(true);
      setError("");
      const [siteData, doctorData, logData, versionData, mariaDBData, statusData, settingsData, configData] = await Promise.all([
        api.getSites(),
        api.getDoctor(),
        api.getLogs(),
        api.getPHPVersions(),
        api.getMariaDB(),
        api.getServiceStatus(),
        api.getSettings(),
        api.getConfigFiles()
      ]);
      setSites(siteData);
      setDoctorChecks(doctorData);
      setLogs(logData.content);
      setVersions(versionData);
      setMariaDB(mariaDBData);
      setServiceStatus(statusData.status);
      setSettings(settingsData);
      setConfigs(configData);
    } catch (refreshError) {
      setError(refreshError.message);
    } finally {
      setIsRefreshing(false);
    }
  };

  useEffect(() => {
    void refresh();
    void desktop.getMeta().then(setAppMeta).catch(() => null);
    const unsubscribe = desktop.onUpdateStatus(setUpdateState);
    return () => unsubscribe();
  }, []);

  useEffect(() => {
    if (!mariaDB?.busy) {
      return undefined;
    }

    const interval = window.setInterval(() => {
      void refresh();
    }, 1000);

    return () => window.clearInterval(interval);
  }, [mariaDB?.busy]);

  const wrap = async (action) => {
    try {
      setError("");
      await action();
      await refresh();
    } catch (actionError) {
      setError(actionError.message);
    }
  };

  const checkForUpdates = async () => {
    try {
      setError("");
      setUpdateState({ status: "checking" });
      const result = await desktop.checkForUpdates();
      setUpdateState((current) => ({ ...current, ...result }));
    } catch (updateError) {
      setUpdateState({ status: "error", message: updateError.message });
      setError(updateError.message);
    }
  };

  const openExternal = async (url) => {
    try {
      await desktop.openExternal(url);
    } catch (openError) {
      setError(openError.message);
    }
  };

  return (
    <div className="flex h-screen flex-col bg-zinc-50 text-zinc-950">
      {/* Fixed header */}
      <div className="h-8 flex-none bg-white" style={{ WebkitAppRegion: "drag" }} />
      <header
        className="flex h-11 flex-none items-center justify-between border-b border-zinc-200 bg-white pl-5 pr-4"
        style={{ WebkitAppRegion: "drag" }}
      >
        <div className="flex items-center gap-2">
          <span className="text-[13px] font-semibold text-zinc-900">Nest <span className="font-normal text-zinc-400">v{appMeta.version}</span></span>
          <Badge variant={serviceVariant[serviceStatus] || "default"}>{serviceStatus}</Badge>
        </div>

        <div className="flex items-center gap-1.5" style={{ WebkitAppRegion: "no-drag" }}>
          {serviceStatus === "running" ? (
            <Button size="sm" variant="outline" onClick={() => wrap(() => api.stopServices())}>
              <Square className="h-3 w-3 fill-current" />
              Stop
            </Button>
          ) : (
            <Button size="sm" onClick={() => wrap(() => api.startServices())}>
              <Play className="h-3 w-3 fill-current" />
              Start
            </Button>
          )}
          <Separator orientation="vertical" className="mx-1 h-4" />
          <Button
            size="iconSm"
            variant="ghost"
            onClick={() => wrap(() => api.reloadServices())}
            title="Reload config"
          >
            <RotateCcw className="h-3.5 w-3.5" />
          </Button>
          <Button
            size="iconSm"
            variant="ghost"
            onClick={refresh}
            title="Refresh data"
          >
            <RefreshCw className={cn("h-3.5 w-3.5", isRefreshing && "animate-spin")} />
          </Button>
        </div>
      </header>

      {error && (
        <div className="flex flex-none items-center justify-between border-b border-red-200 bg-red-50 px-6 py-2 text-[13px] text-red-600">
          <span>{error}</span>
          <button onClick={() => setError("")} className="ml-4 font-medium text-red-400 hover:text-red-600">&times;</button>
        </div>
      )}

      {/* Sidebar + Content */}
      <div className="flex flex-1 overflow-hidden">
        <aside className="flex w-48 flex-none flex-col border-r border-zinc-200 bg-white p-2">
          <nav className="space-y-0.5">
            {tabs.map((tab) => {
              const Icon = tab.icon;
              const active = activeTab === tab.value;
              return (
                <button
                  key={tab.value}
                  onClick={() => setActiveTab(tab.value)}
                  className={cn(
                    "flex w-full items-center gap-2.5 rounded-md px-3 py-2 text-[13px] font-medium transition-colors",
                    active
                      ? "bg-zinc-100 text-zinc-900"
                      : "text-zinc-500 hover:bg-zinc-50 hover:text-zinc-900"
                  )}
                >
                  <Icon className={cn("h-4 w-4", active ? "text-zinc-900" : "text-zinc-400")} />
                  {tab.label}
                </button>
              );
            })}
          </nav>

          <div className="mt-auto border-t border-zinc-100 pt-3 pb-1 px-3">
            <p className="text-[11px] text-zinc-400">v{appMeta.version}</p>
          </div>
        </aside>

        <main className="flex-1 overflow-y-auto">
          <div className="mx-auto max-w-5xl p-6">
            {activeTab === "dashboard" && (
              <DashboardScreen
                doctorChecks={doctorChecks}
                serviceStatus={serviceStatus}
                sites={sites}
                onFixCheck={(id) => wrap(() => api.fixDoctorCheck(id))}
              />
            )}
            {activeTab === "sites" && (
              <SitesScreen
                sites={sites}
                versions={versions}
                onCreate={(payload) => wrap(() => api.createSite(payload))}
                onDelete={(id) => wrap(() => api.deleteSite(id))}
                onExport={() => desktop.exportSites()}
                onImport={async () => {
                  const result = await desktop.importSites();
                  if (result.imported) await refresh();
                  return result;
                }}
                onOpenUrl={openExternal}
                onPickDirectory={() => desktop.pickDirectory()}
                onStart={(id) => wrap(() => api.startSite(id))}
                onStop={(id) => wrap(() => api.stopSite(id))}
                onUpdate={(id, payload) => wrap(() => api.updateSite(id, payload))}
              />
            )}
            {activeTab === "config" && (
              <ConfigScreen
                configs={configs}
                onSave={async (name, content) => {
                  await api.saveConfigFile(name, content);
                  const configData = await api.getConfigFiles();
                  setConfigs(configData);
                }}
                onReload={() => api.reloadServices()}
              />
            )}
            {activeTab === "logs" && (
              <LogsScreen
                content={logs}
                onClear={() => wrap(async () => { await api.clearLogs(); setLogs(""); })}
              />
            )}
            {activeTab === "php" && (
              <PHPVersionsScreen
                versions={versions}
                onInstall={(version) => wrap(() => api.installPHP(version))}
                onActivate={(version) => wrap(() => api.activatePHP(version))}
              />
            )}
            {activeTab === "mariadb" && (
              <MariaDBScreen
                runtime={mariaDB}
                onInstall={() => wrap(() => api.installMariaDB())}
                onStart={() => wrap(() => api.startMariaDB())}
                onStop={() => wrap(() => api.stopMariaDB())}
                onCheckUpdates={async () => {
                  const runtime = await api.checkMariaDBUpdates();
                  setMariaDB(runtime);
                }}
              />
            )}
            {activeTab === "settings" && (
              <SettingsScreen
                appMeta={appMeta}
                settings={settings}
                doctorChecks={doctorChecks}
                onBootstrap={() => wrap(() => api.bootstrapTestDomain())}
                onCheckUpdates={checkForUpdates}
                onInstallUpdate={() => desktop.installUpdate()}
                onTrustLocalCA={() => wrap(() => api.trustLocalCA())}
                updateState={updateState}
              />
            )}
          </div>
        </main>
      </div>
    </div>
  );
}
