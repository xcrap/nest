import { useEffect, useState } from "react";

import { Shell } from "./components/Shell";
import { api } from "./lib/api";
import { DashboardScreen } from "./screens/DashboardScreen";
import { LogsScreen } from "./screens/LogsScreen";
import { PHPVersionsScreen } from "./screens/PHPVersionsScreen";
import { SettingsScreen } from "./screens/SettingsScreen";
import { SitesScreen } from "./screens/SitesScreen";

const tabs = ["Dashboard", "Websites", "Logs", "PHP Versions", "Settings"];

export default function App() {
  const [activeTab, setActiveTab] = useState("Dashboard");
  const [sites, setSites] = useState([]);
  const [doctorChecks, setDoctorChecks] = useState([]);
  const [logs, setLogs] = useState("");
  const [versions, setVersions] = useState([]);
  const [serviceStatus, setServiceStatus] = useState("unknown");
  const [error, setError] = useState("");
  const [isRefreshing, setIsRefreshing] = useState(false);

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

  return (
    <Shell>
      <div className="app-shell">
        <aside className="sidebar">
          <div>
            <p className="eyebrow">macOS-first local PHP</p>
            <h1>Nest</h1>
            <p className="sidebar__copy">FrankenPHP, `.test`, HTTPS, shell integration, and one source of truth.</p>
          </div>
          <nav className="nav">
            {tabs.map((tab) => (
              <button
                className={tab === activeTab ? "nav__item nav__item--active" : "nav__item"}
                key={tab}
                onClick={() => setActiveTab(tab)}
              >
                {tab}
              </button>
            ))}
          </nav>
          <div className="status-pill">
            <span className={`status-dot status-dot--${serviceStatus}`} />
            Service: {serviceStatus}
          </div>
        </aside>

        <main className="main-panel">
          <header className="hero">
            <div>
              <p className="eyebrow">Control Plane</p>
              <h2>Manage local PHP sites without Homebrew drift.</h2>
            </div>
            <button className="button--ghost" onClick={refresh}>
              {isRefreshing ? "Refreshing..." : "Refresh"}
            </button>
          </header>

          {error ? <div className="error-banner">{error}</div> : null}

          {activeTab === "Dashboard" ? (
            <DashboardScreen
              doctorChecks={doctorChecks}
              serviceStatus={serviceStatus}
              sites={sites}
              onStartServices={() => wrap(() => api.startServices())}
              onStopServices={() => wrap(() => api.stopServices())}
              onReloadServices={() => wrap(() => api.reloadServices())}
            />
          ) : null}

          {activeTab === "Websites" ? (
            <SitesScreen
              sites={sites}
              onCreate={(payload) => wrap(() => api.createSite(payload))}
              onDelete={(id) => wrap(() => api.deleteSite(id))}
              onStart={(id) => wrap(() => api.startSite(id))}
              onStop={(id) => wrap(() => api.stopSite(id))}
            />
          ) : null}

          {activeTab === "Logs" ? <LogsScreen content={logs} onRefresh={refresh} /> : null}

          {activeTab === "PHP Versions" ? (
            <PHPVersionsScreen
              versions={versions}
              onInstall={(version) => wrap(() => api.installPHP(version))}
              onActivate={(version) => wrap(() => api.activatePHP(version))}
            />
          ) : null}

          {activeTab === "Settings" ? (
            <SettingsScreen
              doctorChecks={doctorChecks}
              onBootstrap={() => wrap(() => api.bootstrapTestDomain())}
              onTrustLocalCA={() => wrap(() => api.trustLocalCA())}
            />
          ) : null}
        </main>
      </div>
    </Shell>
  );
}
