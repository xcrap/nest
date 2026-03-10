import { AlertTriangle, Activity, FolderKanban, RotateCcw, ShieldCheck, Sparkles } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "../components/ui/card";
import { Separator } from "../components/ui/separator";
import { formatRelativeDate } from "../lib/utils";

const statusVariant = {
  running: "success",
  stopped: "warning",
  unknown: "default"
};

const doctorVariant = {
  pass: "success",
  warn: "warning",
  fail: "danger"
};

export function DashboardScreen({ sites, doctorChecks, serviceStatus, onStartServices, onStopServices, onReloadServices }) {
  const runningSites = sites.filter((site) => site.status === "running").length;
  const doctorWarnings = doctorChecks.filter((check) => check.status !== "pass");
  const latestSites = [...sites]
    .sort((left, right) => new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime())
    .slice(0, 3);

  return (
    <div className="space-y-6">
      <Card className="overflow-hidden border-slate-200/80 bg-[linear-gradient(135deg,rgba(255,255,255,0.96),rgba(241,245,249,0.88))]">
        <CardContent className="grid gap-8 px-6 py-6 lg:grid-cols-[minmax(0,1fr)_320px] lg:px-8 lg:py-8">
          <div className="space-y-6">
            <div className="flex flex-wrap items-center gap-3">
              <Badge variant={statusVariant[serviceStatus] || "default"}>Service {serviceStatus}</Badge>
              <Badge variant="accent">FrankenPHP + HTTPS</Badge>
            </div>
            <div className="space-y-3">
              <h2 className="max-w-3xl text-4xl font-semibold tracking-tight text-slate-950 lg:text-5xl">
                Local PHP environments with one control plane.
              </h2>
              <p className="max-w-2xl text-base leading-7 text-slate-600">
                Start the runtime, manage site routing, and keep TLS and shell integration visible from a single dashboard.
              </p>
            </div>
            <div className="flex flex-wrap gap-3">
              <Button onClick={onStartServices}>Start services</Button>
              <Button variant="secondary" onClick={onReloadServices}>
                <RotateCcw className="h-4 w-4" />
                Reload config
              </Button>
              <Button variant="outline" onClick={onStopServices}>
                Stop runtime
              </Button>
            </div>
          </div>

          <div className="grid gap-4 rounded-[28px] border border-white/80 bg-slate-950 p-5 text-white shadow-[0_20px_80px_rgba(15,23,42,0.3)]">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm uppercase tracking-[0.24em] text-slate-400">Live state</p>
                <h3 className="mt-2 text-2xl font-semibold">Nest runtime</h3>
              </div>
              <Sparkles className="h-5 w-5 text-sky-300" />
            </div>
            <Separator className="bg-white/10" />
            <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-1">
              <StatBlock icon={Activity} label="Runtime" value={serviceStatus} />
              <StatBlock icon={FolderKanban} label="Running sites" value={String(runningSites)} />
              <StatBlock icon={AlertTriangle} label="Doctor alerts" value={String(doctorWarnings.length)} />
            </div>
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(340px,0.9fr)]">
        <Card>
          <CardHeader>
            <CardTitle>Doctor board</CardTitle>
            <CardDescription>Everything that still needs attention before the stack is fully ready.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {doctorChecks.length === 0 ? <EmptyState message="No doctor checks reported yet." /> : null}
            {doctorChecks.map((check) => (
              <article
                className="flex items-start justify-between gap-4 rounded-2xl border border-slate-200/80 bg-slate-50/80 p-4"
                key={check.id}
              >
                <div className="space-y-1">
                  <div className="flex items-center gap-2">
                    <ShieldCheck className="h-4 w-4 text-slate-400" />
                    <p className="text-sm font-semibold text-slate-950">{check.id}</p>
                  </div>
                  <p className="text-sm text-slate-600">{check.message}</p>
                  {check.fixHint ? <p className="text-xs text-slate-500">{check.fixHint}</p> : null}
                </div>
                <Badge variant={doctorVariant[check.status] || "default"}>{check.status}</Badge>
              </article>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Recently changed sites</CardTitle>
            <CardDescription>Quick visibility into the projects you touched last.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {latestSites.length === 0 ? <EmptyState message="No sites are registered yet." /> : null}
            {latestSites.map((site) => (
              <article className="rounded-2xl border border-slate-200/80 bg-white p-4 shadow-sm" key={site.id}>
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <p className="text-base font-semibold text-slate-950">{site.name}</p>
                    <p className="text-sm text-slate-500">{site.domain}</p>
                  </div>
                  <Badge variant={site.status === "running" ? "success" : "default"}>{site.status}</Badge>
                </div>
                <p className="mt-3 line-clamp-1 text-sm text-slate-600">{site.rootPath}</p>
                <p className="mt-3 text-xs text-slate-400">Updated {formatRelativeDate(site.updatedAt)}</p>
              </article>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function StatBlock({ icon: Icon, label, value }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-4">
      <div className="flex items-center gap-2 text-slate-400">
        <Icon className="h-4 w-4" />
        <span className="text-xs uppercase tracking-[0.2em]">{label}</span>
      </div>
      <p className="mt-3 text-3xl font-semibold capitalize text-white">{value}</p>
    </div>
  );
}

function EmptyState({ message }) {
  return <div className="rounded-2xl border border-dashed border-slate-200 bg-slate-50/80 p-8 text-sm text-slate-500">{message}</div>;
}
