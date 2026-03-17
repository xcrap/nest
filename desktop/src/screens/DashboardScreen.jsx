import { Activity, ArrowRight, FolderKanban, ShieldCheck } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";

export function DashboardScreen({ sites, doctorChecks, doctorLoading, serviceStatus, onOpenSettings }) {
  const runningSites = sites.filter((site) => site.status === "running").length;
  const issues = doctorChecks.filter((check) => check.status !== "pass");
  const passCount = Math.max(doctorChecks.length - issues.length, 0);
  const checksLoading = doctorLoading && doctorChecks.length === 0;

  const statusById = new Map(doctorChecks.map((check) => [check.id, check.status]));
  const routingHealthy = statusById.get("test-resolver") === "pass" && statusById.get("privileged-ports") === "pass";
  const httpsHealthy = statusById.get("local-ca") === "pass" && statusById.get("https-localhost") === "pass";
  const runtimesHealthy = [
    "php-symlink",
    "frankenphp-binary",
    "frankenphp-admin",
    "composer-runtime",
    "mariadb-runtime",
    "mariadb-ready"
  ].every((id) => statusById.get(id) === "pass");

  const overallTone = checksLoading
    ? "default"
    : issues.length > 0
      ? "warning"
      : serviceStatus === "running"
        ? "success"
        : "default";
  const overallLabel = checksLoading
    ? "Checking"
    : issues.length > 0
      ? "Attention needed"
      : serviceStatus === "running"
        ? "Healthy"
        : "Stopped";
  const headline = checksLoading
    ? "Checking the local stack."
    : issues.length > 0
      ? "Nest needs review."
      : serviceStatus === "running"
        ? "Nest is ready."
        : "Nest is configured.";
  const message = checksLoading
    ? "Nest is still reading runtime, routing, and certificate state."
    : issues.length > 0
      ? `${issues.length} machine check${issues.length === 1 ? "" : "s"} need attention. Open Settings to review and repair them.`
      : serviceStatus === "running"
        ? "Routing, HTTPS, and runtimes are healthy."
        : "The machine state is healthy, but the web service is not currently running.";

  return (
    <div className="space-y-6">
      <Card className="rounded-3xl border-zinc-200 shadow-[0_18px_50px_-40px_rgba(24,24,27,0.35)]">
        <CardHeader className="pb-4">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="space-y-2">
              <Badge variant={badgeVariant(overallTone)}>{overallLabel}</Badge>
              <div>
                <h2 className="text-3xl font-semibold tracking-[-0.04em] text-zinc-950">{headline}</h2>
                <p className="mt-2 max-w-2xl text-sm leading-6 text-zinc-500">{message}</p>
              </div>
            </div>
            {issues.length > 0 && (
              <Button variant="outline" onClick={onOpenSettings}>
                Review in Settings
                <ArrowRight className="h-3.5 w-3.5" />
              </Button>
            )}
          </div>
        </CardHeader>
        <CardContent>
          <div className="grid gap-3 md:grid-cols-3">
            <OverviewStat
              icon={Activity}
              label="Service"
              value={serviceStatus}
              detail={serviceStatus === "running" ? "FrankenPHP is serving traffic." : serviceStatus === "unknown" ? "Service state is still loading." : "Start the service when you need it."}
            />
            <OverviewStat
              icon={FolderKanban}
              label="Sites"
              value={`${runningSites}/${sites.length}`}
              detail={sites.length === 0 ? "No sites registered yet." : `${runningSites} running, ${sites.length - runningSites} stopped.`}
            />
            <OverviewStat
              icon={ShieldCheck}
              label="Checks"
              value={`${passCount}/${doctorChecks.length || 0}`}
              detail={checksLoading ? "Verification is still loading." : issues.length === 0 ? "All checks are passing." : `${issues.length} need attention.`}
            />
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-4 lg:grid-cols-3">
        <StateCard
          title="Routing"
          status={checksLoading ? "pending" : routingHealthy ? "pass" : "warn"}
          body={checksLoading
            ? "Checking .test resolution and port forwarding."
            : routingHealthy
              ? ".test resolution and ports 80/443 are working."
              : "Routing is not fully healthy. Review Settings for details."}
        />
        <StateCard
          title="HTTPS"
          status={checksLoading ? "pending" : httpsHealthy ? "pass" : "warn"}
          body={checksLoading
            ? "Checking local CA trust and localhost HTTPS."
            : httpsHealthy
              ? "Certificates are trusted and localhost HTTPS is working."
              : "HTTPS trust or localhost certificate validation needs review."}
        />
        <StateCard
          title="Runtimes"
          status={checksLoading ? "pending" : runtimesHealthy ? "pass" : "warn"}
          body={checksLoading
            ? "Checking PHP, FrankenPHP, Composer, and MariaDB."
            : runtimesHealthy
              ? "PHP, Composer, FrankenPHP, and MariaDB are healthy."
              : "One or more managed runtimes need attention."}
        />
      </div>
    </div>
  );
}

function OverviewStat({ icon: Icon, label, value, detail }) {
  return (
    <div className="rounded-2xl border border-zinc-200 bg-zinc-50 p-4">
      <div className="flex items-center gap-2 text-zinc-500">
        <Icon className="h-4 w-4" />
        <span className="text-xs font-medium uppercase tracking-[0.18em]">{label}</span>
      </div>
      <p className="mt-3 text-2xl font-semibold capitalize tracking-[-0.04em] text-zinc-950">{value}</p>
      <p className="mt-1 text-[13px] leading-5 text-zinc-500">{detail}</p>
    </div>
  );
}

function StateCard({ title, status, body }) {
  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between gap-3">
          <CardTitle>{title}</CardTitle>
          <Badge variant={statusBadge(status)}>
            {status === "pending" ? "Checking" : status === "pass" ? "OK" : "Needs review"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent>
        <p className="text-sm leading-6 text-zinc-500">{body}</p>
      </CardContent>
    </Card>
  );
}

function badgeVariant(tone) {
  switch (tone) {
    case "success":
      return "success";
    case "warning":
      return "warning";
    default:
      return "default";
  }
}

function statusBadge(status) {
  switch (status) {
    case "pass":
      return "success";
    case "warn":
      return "warning";
    default:
      return "default";
  }
}
