import { useState } from "react";
import { Check, CircleAlert, DownloadCloud, Github, Loader2, RefreshCw, ShieldCheck, Stethoscope, TerminalSquare } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Separator } from "../components/ui/separator";
import { formatRelativeDate } from "../lib/utils";

const doctorVariant = {
  pass: "success",
  warn: "warning",
  fail: "danger"
};

export function SettingsScreen({ doctorChecks, onBootstrap, onTrustLocalCA, appMeta, settings, updateState, onCheckUpdates, onOpenUpdate }) {
  const bootstrap = settings?.bootstrap;
  const testDomainDone = bootstrap?.testDomainConfigured ?? false;
  const localCATrusted = bootstrap?.localCATrusted ?? false;

  return (
    <div className="space-y-6">
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Machine bootstrap</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <BootstrapRow
              icon={TerminalSquare}
              title="Install .test routing"
              body="Creates resolver and forwarding for .test domains."
              done={testDomainDone}
              doneLabel="Configured"
              actionLabel="Run bootstrap"
              onAction={onBootstrap}
            />
            <BootstrapRow
              icon={ShieldCheck}
              title="Trust local HTTPS"
              body="Adds local CA to your keychain for trusted certificates."
              done={localCATrusted}
              doneLabel="Trusted"
              actionLabel="Trust CA"
              variant="outline"
              onAction={onTrustLocalCA}
            />
            {bootstrap?.lastBootstrapCompleted && (
              <p className="text-xs text-zinc-400">
                Last bootstrap: {formatRelativeDate(bootstrap.lastBootstrapCompleted)}
              </p>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <div className="flex items-center justify-between">
              <CardTitle>Release</CardTitle>
              <Badge variant="accent">v{appMeta.version}</Badge>
            </div>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="space-y-1.5 rounded-md border border-zinc-100 bg-zinc-50 p-3 text-[13px]">
              <MetaRow label="Version" value={`v${appMeta.version}`} />
              <MetaRow label="Build" value={appMeta.packaged ? "Packaged" : "Development"} />
              <MetaRow label="Platform" value={`${appMeta.platform} ${appMeta.arch}`} />
            </div>
            <Separator />
            <div className="flex items-center justify-between gap-3">
              <div>
                <p className="text-sm font-medium text-zinc-900">Updates</p>
                <p className="text-[13px] text-zinc-500">
                  {updateState.message || "Check for new releases."}
                </p>
              </div>
              <Button size="sm" variant="outline" onClick={onCheckUpdates}>
                <RefreshCw className="h-3.5 w-3.5" />
                Check
              </Button>
            </div>
            {updateState.latestVersion && (
              <div className="rounded-md border border-zinc-200 bg-white p-3 text-[13px]">
                <p className="font-medium text-zinc-900">v{updateState.latestVersion}</p>
                {updateState.publishedAt && (
                  <p className="text-xs text-zinc-400">{formatRelativeDate(updateState.publishedAt)}</p>
                )}
                <div className="mt-2 flex gap-2">
                  {updateState.asset?.url && (
                    <Button size="sm" onClick={() => onOpenUpdate(updateState.asset.url)}>
                      <DownloadCloud className="h-3.5 w-3.5" />
                      Download
                    </Button>
                  )}
                  {updateState.htmlUrl && (
                    <Button size="sm" variant="outline" onClick={() => onOpenUpdate(updateState.htmlUrl)}>
                      <Github className="h-3.5 w-3.5" />
                      Release
                    </Button>
                  )}
                </div>
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Doctor checks</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2">
          {doctorChecks.map((check) => (
            <div
              key={check.id}
              className="flex items-start justify-between gap-3 rounded-md border border-zinc-100 bg-zinc-50 p-3"
            >
              <div className="min-w-0 space-y-0.5">
                <div className="flex items-center gap-1.5">
                  <Stethoscope className="h-3.5 w-3.5 text-zinc-400" />
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
    </div>
  );
}

function BootstrapRow({ icon: Icon, title, body, done, doneLabel, actionLabel, variant, onAction }) {
  const [running, setRunning] = useState(false);

  const handleAction = async () => {
    setRunning(true);
    try {
      await onAction();
    } finally {
      setRunning(false);
    }
  };

  return (
    <div className="flex items-center justify-between gap-3 rounded-md border border-zinc-100 bg-zinc-50 p-3">
      <div className="flex items-center gap-3">
        <div className="flex h-8 w-8 items-center justify-center rounded-md border border-zinc-200 bg-white text-zinc-600">
          <Icon className="h-4 w-4" />
        </div>
        <div>
          <p className="text-sm font-medium text-zinc-900">{title}</p>
          <p className="text-[13px] text-zinc-500">{body}</p>
        </div>
      </div>
      {done ? (
        <Badge variant="success">
          <Check className="h-3 w-3" />
          {doneLabel}
        </Badge>
      ) : (
        <Button size="sm" variant={variant} onClick={handleAction} disabled={running}>
          {running ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null}
          {actionLabel}
        </Button>
      )}
    </div>
  );
}

function MetaRow({ label, value }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-zinc-500">{label}</span>
      <span className="font-medium text-zinc-900">{value}</span>
    </div>
  );
}
