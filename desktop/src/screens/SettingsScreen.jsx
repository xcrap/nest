import { useState } from "react";
import { Check, CircleAlert, Loader2, RefreshCw, RotateCcw, ShieldCheck, Stethoscope, TerminalSquare } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { doctorCheckHelpText, doctorCheckLabel, fixableDoctorChecks } from "../lib/doctor";
import { Separator } from "../components/ui/separator";
import { formatRelativeDate } from "../lib/utils";

const doctorVariant = {
  pass: "success",
  warn: "warning",
  fail: "danger"
};

export function SettingsScreen({ doctorChecks, onBootstrap, onUnbootstrap, onTrustLocalCA, onUntrustLocalCA, onFixCheck, appMeta, settings, updateState, onCheckUpdates, onInstallUpdate }) {
  const bootstrap = settings?.bootstrap;
  const doctorStatus = new Map(doctorChecks.map((check) => [check.id, check.status]));
  const hasDoctorChecks = doctorChecks.length > 0;
  const doctorIssues = doctorChecks.filter((check) => check.status !== "pass");
  const verifiedChecks = doctorChecks.filter((check) => check.status === "pass");
  const testDomainDone = hasDoctorChecks
    ? doctorStatus.get("test-resolver") === "pass" && doctorStatus.get("privileged-ports") === "pass"
    : (bootstrap?.testDomainConfigured ?? false);
  const localCATrusted = hasDoctorChecks
    ? doctorStatus.get("local-ca") === "pass"
    : (bootstrap?.localCATrusted ?? false);

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
              body="Creates the resolver and privileged forwarding for .test domains."
              done={testDomainDone}
              doneLabel="Configured"
              actionLabel="Run bootstrap"
              onAction={onBootstrap}
              onUndo={onUnbootstrap}
              undoLabel="Remove"
            />
            <BootstrapRow
              icon={ShieldCheck}
              title="Trust local HTTPS"
              body="Adds Nest's local CA to the keychain so certificates are trusted."
              done={localCATrusted}
              doneLabel="Trusted"
              actionLabel="Trust CA"
              variant="outline"
              onAction={onTrustLocalCA}
              onUndo={onUntrustLocalCA}
              undoLabel="Untrust"
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
                  {updateState.status === "checking" ? "Checking for updates..." :
                   updateState.status === "downloading" ? `Downloading update... ${updateState.percent ?? 0}%` :
                   "Check for new releases."}
                </p>
              </div>
              {updateState.status !== "ready" && (
                <Button
                  size="sm"
                  variant="outline"
                  onClick={onCheckUpdates}
                  disabled={updateState.status === "checking" || updateState.status === "downloading"}
                >
                  {(updateState.status === "checking" || updateState.status === "downloading")
                    ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    : <RefreshCw className="h-3.5 w-3.5" />}
                  Check
                </Button>
              )}
            </div>
            {updateState.status === "current" && (
              <div className="flex items-center gap-2 rounded-md border border-emerald-200 bg-emerald-50 p-3 text-[13px]">
                <Check className="h-4 w-4 text-emerald-600" />
                <p className="font-medium text-emerald-800">You're on the latest version (v{appMeta.version})</p>
              </div>
            )}
            {updateState.status === "downloading" && (
              <div className="rounded-md border border-zinc-200 bg-white p-3">
                <div className="h-1.5 overflow-hidden rounded-full bg-zinc-100">
                  <div
                    className="h-full rounded-full bg-zinc-900 transition-all"
                    style={{ width: `${updateState.percent ?? 0}%` }}
                  />
                </div>
              </div>
            )}
            {updateState.status === "ready" && (
              <div className="flex items-center justify-between gap-3 rounded-md border border-emerald-200 bg-emerald-50 p-3 text-[13px]">
                <p className="font-medium text-emerald-800">v{updateState.version} is ready to install</p>
                <Button size="sm" onClick={onInstallUpdate}>
                  <RotateCcw className="h-3.5 w-3.5" />
                  Restart
                </Button>
              </div>
            )}
            {updateState.status === "error" && (
              <div className="flex items-center gap-2 rounded-md border border-red-200 bg-red-50 p-3 text-[13px]">
                <CircleAlert className="h-4 w-4 text-red-500" />
                <p className="font-medium text-red-700">{updateState.message || "Update check failed."}</p>
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1.2fr)_minmax(280px,0.8fr)]">
        <Card>
          <CardHeader>
            <div className="flex items-center justify-between gap-3">
              <CardTitle>Verification</CardTitle>
              <Badge variant={doctorIssues.length === 0 ? "success" : "warning"}>
                {doctorIssues.length === 0 ? "Healthy" : `${doctorIssues.length} open`}
              </Badge>
            </div>
          </CardHeader>
          <CardContent className="space-y-3">
            {doctorChecks.length === 0 ? (
              <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3">
                <p className="text-sm font-medium text-zinc-900">Verification is still loading.</p>
                <p className="mt-1 text-[13px] text-zinc-500">Nest has not finished reporting the current machine checks yet.</p>
              </div>
            ) : doctorIssues.length === 0 ? (
              <div className="rounded-md border border-emerald-200 bg-emerald-50 p-3">
                <p className="text-sm font-medium text-emerald-900">All behavioral checks are passing.</p>
                <p className="mt-1 text-[13px] text-emerald-700">Routing, certificates, runtimes, and database health are all verified right now.</p>
              </div>
            ) : (
              doctorIssues.map((check) => (
                <DoctorCheckRow key={check.id} check={check} onFix={onFixCheck} />
              ))
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Verified checks</CardTitle>
          </CardHeader>
          <CardContent>
            {verifiedChecks.length === 0 ? (
              <p className="text-sm text-zinc-500">No checks have passed yet.</p>
            ) : (
              <div className="flex flex-wrap gap-2">
                {verifiedChecks.map((check) => (
                  <Badge key={check.id} variant="success" className="gap-1.5 py-1">
                    <Check className="h-3 w-3" />
                    {doctorCheckLabel(check.id)}
                  </Badge>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function BootstrapRow({ icon: Icon, title, body, done, doneLabel, actionLabel, undoLabel, variant, onAction, onUndo }) {
  const [running, setRunning] = useState(false);

  const run = async (action) => {
    setRunning(true);
    try {
      await action();
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
        <div className="flex items-center gap-2">
          <Badge variant="success" className="gap-1.5">
            <Check className="h-3 w-3" />
            {doneLabel}
          </Badge>
          {onUndo && (
            <Button size="sm" variant="outline" onClick={() => run(onUndo)} disabled={running}>
              {running ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null}
              {undoLabel}
            </Button>
          )}
        </div>
      ) : (
        <Button size="sm" variant={variant} onClick={() => run(onAction)} disabled={running}>
          {running ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null}
          {actionLabel}
        </Button>
      )}
    </div>
  );
}

function DoctorCheckRow({ check, onFix }) {
  const [fixing, setFixing] = useState(false);
  const canFix = check.status !== "pass" && fixableDoctorChecks.has(check.id);
  const helpText = doctorCheckHelpText(check);

  const handleFix = async () => {
    setFixing(true);
    try {
      await onFix(check.id);
    } finally {
      setFixing(false);
    }
  };

  return (
    <div className="flex items-start justify-between gap-3 rounded-md border border-zinc-100 bg-zinc-50 p-3">
      <div className="min-w-0 space-y-0.5">
        <div className="flex items-center gap-1.5">
          <Stethoscope className="h-3.5 w-3.5 text-zinc-400" />
          <span className="text-sm font-medium text-zinc-900">{doctorCheckLabel(check.id)}</span>
        </div>
        <p className="text-[13px] text-zinc-500">{check.message}</p>
        {helpText && <p className="text-xs text-zinc-400">{helpText}</p>}
      </div>
      <div className="flex shrink-0 items-center gap-2">
        {canFix && (
          <Button size="sm" variant="outline" onClick={handleFix} disabled={fixing}>
            {fixing ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null}
            Fix
          </Button>
        )}
        <Badge variant={doctorVariant[check.status] || "default"}>{check.status}</Badge>
      </div>
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
