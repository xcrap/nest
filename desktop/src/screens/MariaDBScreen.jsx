import { useState } from "react";
import { CheckCircle2, Database, Download, Loader2, Pin, Play, RefreshCw, Server, Square } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";

const statusVariant = {
  running: "success",
  stopped: "warning",
  unknown: "default"
};

export function MariaDBScreen({ runtime, onInstall, onStart, onStop, onCheckUpdates }) {
  const [loading, setLoading] = useState("");
  const installed = runtime?.installed ?? false;
  const status = runtime?.status || "unknown";
  const busy = runtime?.busy ?? false;
  const passwordLabel = runtime ? (runtime.passwordlessRoot ? "No password" : "Configured") : "No password";

  const run = async (key, action) => {
    setLoading(key);
    try {
      await action();
    } finally {
      setLoading("");
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2">
        <Database className="h-5 w-5 text-zinc-500" />
        <h2 className="text-lg font-semibold text-zinc-900">MariaDB</h2>
        <Badge variant={statusVariant[status] || "default"}>{status}</Badge>
      </div>

      <div className="grid gap-4 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <Card>
          <CardHeader>
            <CardTitle>Runtime</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <InfoRow label="Installed version" value={runtime?.installedVersion || "Not installed"} />
            <InfoRow label="Formula" value={runtime?.formula || "mariadb@10.11"} />
            <InfoRow label="Pinned" value={runtime?.pinned ? "Yes" : "No"} />
            <InfoRow label="Socket" value={runtime?.socketPath || "Not configured"} mono />
            <InfoRow label="Data directory" value={runtime?.dataDir || "Not configured"} mono />
            <InfoRow label="Homebrew prefix" value={runtime?.prefix || "Not configured"} mono />
            <InfoRow label="Port" value={runtime?.port ? String(runtime.port) : "3306"} />
            <InfoRow label="Root access" value="root / no password" />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Actions</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <Button
              className="w-full justify-start"
              onClick={() => run("install", onInstall)}
              disabled={loading !== "" || busy}
            >
                  {loading === "install" || (busy && runtime?.activity === "install") ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : installed ? <RefreshCw className="h-3.5 w-3.5" /> : <Download className="h-3.5 w-3.5" />}
                  {installed ? "Repair Homebrew runtime" : "Install with Homebrew"}
            </Button>

            {status === "running" ? (
              <Button
                className="w-full justify-start"
                variant="outline"
                onClick={() => run("stop", onStop)}
                disabled={loading !== "" || busy}
              >
                {loading === "stop" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Square className="h-3.5 w-3.5 fill-current" />}
                Stop service
              </Button>
            ) : (
              <Button
                className="w-full justify-start"
                variant="outline"
                onClick={() => run("start", onStart)}
                disabled={!installed || loading !== "" || busy}
              >
                {loading === "start" || (busy && runtime?.activity === "start") ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Play className="h-3.5 w-3.5 fill-current" />}
                Start service
              </Button>
            )}

            <Button
              className="w-full justify-start"
              variant="outline"
              onClick={() => run("updates", onCheckUpdates)}
              disabled={loading !== "" || busy}
            >
              {loading === "updates" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Pin className="h-3.5 w-3.5" />}
              Verify formula and pin
            </Button>

            {busy && (
              <div className="rounded-md border border-blue-200 bg-blue-50 p-3 text-[13px] text-blue-700">
                <div className="flex items-center gap-2">
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  <span>{runtime?.activity === "install" ? "Installing MariaDB" : "Starting MariaDB"}</span>
                </div>
                {runtime?.activityMessage && <p className="mt-1 text-blue-700/90">{runtime.activityMessage}</p>}
              </div>
            )}

            {!busy && runtime?.lastError && (
              <div className="rounded-md border border-red-200 bg-red-50 p-3 text-[13px] text-red-700">
                {runtime.lastError}
              </div>
            )}

            {!busy && installed && runtime && !runtime.pinned && (
              <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-[13px] text-amber-700">
                Homebrew formula is installed but not pinned yet.
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Connection defaults</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3 text-[13px] lg:grid-cols-3">
          <ConnectionCard icon={Server} label="Host" value="127.0.0.1" />
          <ConnectionCard icon={CheckCircle2} label="User" value={runtime?.rootUser || "root"} />
          <ConnectionCard icon={CheckCircle2} label="Password" value={passwordLabel} />
        </CardContent>
      </Card>
    </div>
  );
}

function InfoRow({ label, value, mono = false }) {
  return (
    <div className="rounded-md border border-zinc-100 bg-zinc-50 px-3 py-2.5">
      {mono ? (
        <div className="space-y-1.5">
          <span className="block text-zinc-500">{label}</span>
          <span className="block break-all font-mono text-[13px] text-zinc-900 select-text">{value}</span>
        </div>
      ) : (
        <div className="flex items-start justify-between gap-3">
          <span className="text-zinc-500">{label}</span>
          <span className="font-medium text-zinc-900">{value}</span>
        </div>
      )}
    </div>
  );
}

function ConnectionCard({ icon: Icon, label, value }) {
  return (
    <div className="rounded-md border border-zinc-100 bg-zinc-50 p-3">
      <div className="flex items-center gap-1.5 text-zinc-500">
        <Icon className="h-3.5 w-3.5" />
        <span className="text-xs font-medium uppercase tracking-[0.08em]">{label}</span>
      </div>
      <p className="mt-2 text-sm font-semibold text-zinc-900">{value}</p>
    </div>
  );
}
