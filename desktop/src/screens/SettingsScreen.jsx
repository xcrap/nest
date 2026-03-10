import { DownloadCloud, Github, RefreshCw, ShieldCheck, Stethoscope, TerminalSquare } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "../components/ui/card";
import { Separator } from "../components/ui/separator";
import { formatRelativeDate } from "../lib/utils";

const doctorVariant = {
  pass: "success",
  warn: "warning",
  fail: "danger"
};

export function SettingsScreen({ doctorChecks, onBootstrap, onTrustLocalCA, appMeta, updateState, onCheckUpdates, onOpenUpdate }) {
  return (
    <div className="space-y-6">
      <div className="grid gap-6 xl:grid-cols-[minmax(0,1fr)_380px]">
        <Card>
          <CardHeader>
            <CardTitle>Machine bootstrap</CardTitle>
            <CardDescription>Run the one-time macOS steps that let `.test` domains and local TLS behave like first-class sites.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <ActionRow
              icon={TerminalSquare}
              title="Install .test routing"
              body="Creates the resolver and local forwarding required for `.test` domains on this Mac."
              action={<Button onClick={onBootstrap}>Run bootstrap</Button>}
            />
            <ActionRow
              icon={ShieldCheck}
              title="Trust local HTTPS"
              body="Adds the local Caddy CA to your login keychain so browsers trust site certificates."
              action={
                <Button variant="secondary" onClick={onTrustLocalCA}>
                  Trust certificates
                </Button>
              }
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <div className="flex items-center justify-between gap-3">
              <div>
                <CardTitle>App release</CardTitle>
                <CardDescription>Track build version, release source, and downloadable updates.</CardDescription>
              </div>
              <Badge variant="accent">v{appMeta.version}</Badge>
            </div>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50/80 p-4 text-sm text-slate-600">
              <ReleaseMeta label="Current version" value={`v${appMeta.version}`} />
              <ReleaseMeta label="Build type" value={appMeta.packaged ? "Packaged app" : "Development build"} />
              <ReleaseMeta label="Platform" value={`${appMeta.platform} ${appMeta.arch}`} />
            </div>
            <Separator />
            <div className="space-y-3">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <p className="text-sm font-medium text-slate-950">Update feed</p>
                  <p className="text-sm text-slate-500">
                    {updateState.message || (appMeta.releaseFeedConfigured ? "Check GitHub Releases for the latest DMG." : "Release feed is not configured yet.")}
                  </p>
                </div>
                <Button variant="outline" onClick={onCheckUpdates}>
                  <RefreshCw className="h-4 w-4" />
                  Check
                </Button>
              </div>
              {updateState.latestVersion ? (
                <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600">
                  <p className="font-medium text-slate-950">Latest release</p>
                  <p className="mt-1">v{updateState.latestVersion}</p>
                  {updateState.publishedAt ? <p className="mt-1 text-xs text-slate-400">Published {formatRelativeDate(updateState.publishedAt)}</p> : null}
                  <div className="mt-3 flex flex-wrap gap-2">
                    {updateState.asset?.url ? (
                      <Button onClick={() => onOpenUpdate(updateState.asset.url)}>
                        <DownloadCloud className="h-4 w-4" />
                        Download {updateState.asset.name}
                      </Button>
                    ) : null}
                    {updateState.htmlUrl ? (
                      <Button variant="secondary" onClick={() => onOpenUpdate(updateState.htmlUrl)}>
                        <Github className="h-4 w-4" />
                        Open release
                      </Button>
                    ) : null}
                  </div>
                </div>
              ) : null}
              <p className="text-xs leading-5 text-slate-400">
                Nest can already check GitHub Releases and open the matching DMG or ZIP. Fully automatic in-place updating on
                macOS should be enabled only after the app is signed and notarized.
              </p>
            </div>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Doctor checks</CardTitle>
          <CardDescription>Everything Nest can currently validate about the local stack.</CardDescription>
        </CardHeader>
        <CardContent className="grid gap-3">
          {doctorChecks.map((check) => (
            <article className="flex items-start justify-between gap-4 rounded-2xl border border-slate-200 bg-slate-50/80 p-4" key={check.id}>
              <div className="space-y-1">
                <div className="flex items-center gap-2">
                  <Stethoscope className="h-4 w-4 text-slate-400" />
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
    </div>
  );
}

function ActionRow({ icon: Icon, title, body, action }) {
  return (
    <div className="flex flex-col gap-4 rounded-2xl border border-slate-200 bg-slate-50/80 p-4 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex gap-3">
        <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-white text-slate-700 shadow-sm ring-1 ring-slate-200">
          <Icon className="h-5 w-5" />
        </div>
        <div>
          <p className="text-sm font-semibold text-slate-950">{title}</p>
          <p className="mt-1 text-sm text-slate-600">{body}</p>
        </div>
      </div>
      <div>{action}</div>
    </div>
  );
}

function ReleaseMeta({ label, value }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-slate-500">{label}</span>
      <span className="font-medium text-slate-950">{value}</span>
    </div>
  );
}
