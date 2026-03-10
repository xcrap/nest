import { useEffect, useMemo, useState } from "react";
import { Code2, FileText, Globe2, LayoutDashboard, RefreshCw, Settings2, Sparkles } from "lucide-react";

import { Badge } from "./components/ui/badge";
import { Button } from "./components/ui/button";
import { Card, CardContent } from "./components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "./components/ui/tabs";
import { api, desktop } from "./lib/api";
import { DashboardScreen } from "./screens/DashboardScreen";
import { LogsScreen } from "./screens/LogsScreen";
import { PHPVersionsScreen } from "./screens/PHPVersionsScreen";
import { SettingsScreen } from "./screens/SettingsScreen";
import { SitesScreen } from "./screens/SitesScreen";

const tabs = [
  {
    value: "dashboard",
    label: "Dashboard",
    caption: "Service health and doctor status",
    icon: LayoutDashboard,
    eyebrow: "Overview",
    title: "A cleaner control plane for local PHP.",
    body: "Own site routing, runtime state, TLS setup, and CLI versions from one app."
  },
  {
    value: "sites",
    label: "Websites",
    caption: "Create, edit, and route sites",
    icon: Globe2,
    eyebrow: "Projects",
    title: "Manage your domains and project folders.",
    body: "Each site stays editable from the UI, including its local path, runtime, and HTTPS toggle."
  },
  {
    value: "logs",
    label: "Logs",
    caption: "Read runtime output",
    icon: FileText,
    eyebrow: "Observability",
    title: "Inspect runtime output without leaving the app.",
    body: "FrankenPHP logs stay visible here so failures are easy to diagnose."
  },
  {
    value: "php",
    label: "PHP Versions",
    caption: "Install and activate runtimes",
    icon: Code2,
    eyebrow: "Runtimes",
    title: "Switch the machine-wide PHP runtime cleanly.",
    body: "Nest maintains a stable bin directory and points shell usage at the active runtime."
  },
  {
    value: "settings",
    label: "Settings",
    caption: "Bootstrap, doctor, and releases",
    icon: Settings2,
    eyebrow: "System",
    title: "Machine setup, release checks, and repair tools.",
    body: "Use this screen for `.test` bootstrap, certificate trust, and release management."
  }
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
  const [serviceStatus, setServiceStatus] = useState("unknown");
  const [error, setError] = useState("");
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [appMeta, setAppMeta] = useState({
    version: "0.1.0",
    packaged: false,
    platform: "macOS",
    arch: "arm64",
    releaseFeedConfigured: false
  });
  const [updateState, setUpdateState] = useState({
    configured: false,
    status: "idle",
    message: "Release checks have not been run yet."
  });

  const currentTab = useMemo(() => tabs.find((tab) => tab.value === activeTab) || tabs[0], [activeTab]);
  const installedVersions = useMemo(() => versions.filter((version) => version.installed).length, [versions]);
  const runningSites = useMemo(() => sites.filter((site) => site.status === "running").length, [sites]);

  const refresh = async () => {
    try {
      setIsRefreshing(true);
      setError("");
      const [siteData, doctorData, logData, versionData, statusData] = await Promise.all([
        api.getSites(),
        api.getDoctor(),
        api.getLogs(),
        api.getPHPVersions(),
        api.getServiceStatus()
      ]);
      setSites(siteData);
      setDoctorChecks(doctorData);
      setLogs(logData.content);
      setVersions(versionData);
      setServiceStatus(statusData.status);
    } catch (refreshError) {
      setError(refreshError.message);
    } finally {
      setIsRefreshing(false);
    }
  };

  useEffect(() => {
    void refresh();
    void desktop.getMeta().then(setAppMeta).catch(() => null);
  }, []);

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
      setUpdateState((current) => ({ ...current, status: "checking", message: "Checking GitHub Releases..." }));
      const result = await desktop.checkForUpdates();
      setUpdateState(result);
    } catch (updateError) {
      setUpdateState({
        configured: appMeta.releaseFeedConfigured,
        status: "error",
        message: updateError.message
      });
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
    <div className="relative min-h-screen overflow-hidden bg-[linear-gradient(180deg,#f8fafc_0%,#eef2ff_100%)] text-slate-950">
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_top_left,rgba(56,189,248,0.12),transparent_22%),radial-gradient(circle_at_85%_80%,rgba(14,165,233,0.14),transparent_18%)]" />
      <div className="relative mx-auto flex min-h-screen max-w-[1680px] flex-col gap-6 p-4 lg:p-6 xl:flex-row">
        <Tabs className="grid gap-6 xl:grid-cols-[290px_minmax(0,1fr)] xl:flex-1" orientation="vertical" value={activeTab} onValueChange={setActiveTab}>
          <aside className="space-y-6 rounded-[32px] border border-white/80 bg-white/60 p-4 shadow-[0_30px_120px_rgba(15,23,42,0.08)] backdrop-blur-xl xl:p-5">
            <div className="space-y-4 rounded-[28px] bg-slate-950 p-5 text-white shadow-[0_20px_80px_rgba(15,23,42,0.24)]">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <p className="text-xs uppercase tracking-[0.28em] text-slate-400">Nest</p>
                  <h1 className="mt-2 text-3xl font-semibold tracking-tight">Local PHP</h1>
                </div>
                <Sparkles className="h-5 w-5 text-sky-300" />
              </div>
              <p className="text-sm leading-6 text-slate-300">
                A native macOS control panel for websites, runtimes, certificates, and shell integration.
              </p>
              <div className="flex flex-wrap gap-2">
                <Badge variant={serviceVariant[serviceStatus] || "default"}>Service {serviceStatus}</Badge>
                <Badge variant="accent">v{appMeta.version}</Badge>
              </div>
            </div>

            <TabsList>
              {tabs.map((tab) => {
                const Icon = tab.icon;
                const isActive = activeTab === tab.value;
                return (
                  <TabsTrigger className="w-full" key={tab.value} value={tab.value}>
                    <span className="flex items-center gap-3">
                      <span
                        className={
                          isActive
                            ? "flex h-10 w-10 items-center justify-center rounded-2xl bg-slate-950 text-white"
                            : "flex h-10 w-10 items-center justify-center rounded-2xl bg-slate-100 text-slate-700"
                        }
                      >
                        <Icon className="h-4 w-4" />
                      </span>
                      <span>
                        <span className="block text-sm font-semibold">{tab.label}</span>
                        <span className="block text-xs text-slate-400">{tab.caption}</span>
                      </span>
                    </span>
                  </TabsTrigger>
                );
              })}
            </TabsList>

            <Card className="border-slate-200/90 bg-white/80 shadow-none">
              <CardContent className="grid gap-4 px-5 py-5">
                <SidebarStat label="Sites" value={String(sites.length)} />
                <SidebarStat label="Running" value={String(runningSites)} />
                <SidebarStat label="Installed PHP" value={String(installedVersions)} />
              </CardContent>
            </Card>
          </aside>

          <main className="space-y-6">
            <header className="rounded-[32px] border border-white/80 bg-white/70 px-6 py-6 shadow-[0_30px_120px_rgba(15,23,42,0.08)] backdrop-blur-xl lg:px-8">
              <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
                <div className="space-y-3">
                  <p className="text-xs uppercase tracking-[0.28em] text-slate-400">{currentTab.eyebrow}</p>
                  <h2 className="max-w-4xl text-4xl font-semibold tracking-tight text-slate-950 lg:text-5xl">{currentTab.title}</h2>
                  <p className="max-w-2xl text-sm leading-7 text-slate-600">{currentTab.body}</p>
                </div>
                <div className="flex flex-wrap gap-3">
                  <Button variant="secondary" onClick={checkForUpdates}>
                    Check releases
                  </Button>
                  <Button variant="outline" onClick={refresh}>
                    <RefreshCw className="h-4 w-4" />
                    {isRefreshing ? "Refreshing..." : "Refresh state"}
                  </Button>
                </div>
              </div>
              {error ? <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div> : null}
            </header>

            <TabsContent className="m-0" value="dashboard">
              <DashboardScreen
                doctorChecks={doctorChecks}
                serviceStatus={serviceStatus}
                sites={sites}
                onStartServices={() => wrap(() => api.startServices())}
                onStopServices={() => wrap(() => api.stopServices())}
                onReloadServices={() => wrap(() => api.reloadServices())}
              />
            </TabsContent>

            <TabsContent className="m-0" value="sites">
              <SitesScreen
                sites={sites}
                versions={versions}
                onCreate={(payload) => wrap(() => api.createSite(payload))}
                onDelete={(id) => wrap(() => api.deleteSite(id))}
                onOpenUrl={openExternal}
                onPickDirectory={() => desktop.pickDirectory()}
                onStart={(id) => wrap(() => api.startSite(id))}
                onStop={(id) => wrap(() => api.stopSite(id))}
                onUpdate={(id, payload) => wrap(() => api.updateSite(id, payload))}
              />
            </TabsContent>

            <TabsContent className="m-0" value="logs">
              <LogsScreen content={logs} onRefresh={refresh} />
            </TabsContent>

            <TabsContent className="m-0" value="php">
              <PHPVersionsScreen
                versions={versions}
                onInstall={(version) => wrap(() => api.installPHP(version))}
                onActivate={(version) => wrap(() => api.activatePHP(version))}
              />
            </TabsContent>

            <TabsContent className="m-0" value="settings">
              <SettingsScreen
                appMeta={appMeta}
                doctorChecks={doctorChecks}
                onBootstrap={() => wrap(() => api.bootstrapTestDomain())}
                onCheckUpdates={checkForUpdates}
                onOpenUpdate={openExternal}
                onTrustLocalCA={() => wrap(() => api.trustLocalCA())}
                updateState={updateState}
              />
            </TabsContent>
          </main>
        </Tabs>
      </div>
    </div>
  );
}

function SidebarStat({ label, value }) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-slate-50/80 px-4 py-3">
      <span className="text-sm text-slate-500">{label}</span>
      <span className="text-lg font-semibold text-slate-950">{value}</span>
    </div>
  );
}
