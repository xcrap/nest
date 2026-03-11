import { Activity, AlertTriangle, FolderKanban, ShieldCheck } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { formatRelativeDate } from "../lib/utils";

const doctorVariant = {
  pass: "success",
  warn: "warning",
  fail: "danger"
};

export function DashboardScreen({ sites, doctorChecks, serviceStatus }) {
  const runningSites = sites.filter((site) => site.status === "running").length;
  const doctorWarnings = doctorChecks.filter((check) => check.status !== "pass");
  const latestSites = [...sites]
    .sort((left, right) => new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime())
    .slice(0, 5);

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-4 gap-3">
        <StatCard icon={Activity} label="Service" value={serviceStatus} />
        <StatCard icon={FolderKanban} label="Total sites" value={String(sites.length)} />
        <StatCard icon={FolderKanban} label="Running" value={String(runningSites)} />
        <StatCard icon={AlertTriangle} label="Alerts" value={String(doctorWarnings.length)} />
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Doctor checks</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {doctorChecks.length === 0 && (
              <p className="py-6 text-center text-sm text-zinc-400">No checks reported yet.</p>
            )}
            {doctorChecks.map((check) => (
              <div
                key={check.id}
                className="flex items-start justify-between gap-3 rounded-md border border-zinc-100 bg-zinc-50 p-3"
              >
                <div className="min-w-0 space-y-0.5">
                  <div className="flex items-center gap-1.5">
                    <ShieldCheck className="h-3.5 w-3.5 text-zinc-400" />
                    <span className="text-sm font-medium text-zinc-900">{check.id}</span>
                  </div>
                  <p className="text-[13px] text-zinc-500">{check.message}</p>
                  {check.fixHint && <p className="text-xs text-zinc-400">{check.fixHint}</p>}
                </div>
                <Badge variant={doctorVariant[check.status] || "default"}>{check.status}</Badge>
              </div>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Recent sites</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {latestSites.length === 0 && (
              <p className="py-6 text-center text-sm text-zinc-400">No sites registered yet.</p>
            )}
            {latestSites.map((site) => (
              <div
                key={site.id}
                className="flex items-center justify-between gap-3 rounded-md border border-zinc-100 bg-zinc-50 p-3"
              >
                <div className="min-w-0">
                  <p className="text-sm font-medium text-zinc-900">{site.name}</p>
                  <p className="text-[13px] text-zinc-500">{site.domain}</p>
                </div>
                <div className="flex items-center gap-2">
                  <Badge variant={site.status === "running" ? "success" : "default"}>{site.status}</Badge>
                  <span className="whitespace-nowrap text-xs text-zinc-400">{formatRelativeDate(site.updatedAt)}</span>
                </div>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function StatCard({ icon: Icon, label, value }) {
  return (
    <Card>
      <div className="p-4">
        <div className="flex items-center gap-1.5 text-zinc-500">
          <Icon className="h-3.5 w-3.5" />
          <span className="text-xs font-medium">{label}</span>
        </div>
        <p className="mt-1.5 text-2xl font-semibold capitalize text-zinc-900">{value}</p>
      </div>
    </Card>
  );
}
