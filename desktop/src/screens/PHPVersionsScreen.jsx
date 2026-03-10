import { CheckCircle2, Download, Wand2 } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "../components/ui/card";

export function PHPVersionsScreen({ versions, onInstall, onActivate }) {
  return (
    <div className="space-y-6">
      <Card>
        <CardContent className="flex flex-col gap-4 px-6 py-6 lg:flex-row lg:items-end lg:justify-between lg:px-8">
          <div className="space-y-2">
            <Badge variant="accent">PHP runtimes</Badge>
            <h2 className="text-3xl font-semibold tracking-tight text-slate-950">Install and switch the active CLI runtime.</h2>
            <p className="max-w-2xl text-sm leading-6 text-slate-600">
              Nest keeps a stable local bin directory and points `php` to the currently active version.
            </p>
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-4 xl:grid-cols-2">
        {versions.map((version) => (
          <Card key={version.version} className={version.active ? "border-sky-200 shadow-[0_20px_60px_rgba(14,165,233,0.12)]" : undefined}>
            <CardHeader>
              <div className="flex items-start justify-between gap-3">
                <div>
                  <CardTitle className="text-xl">PHP {version.version}</CardTitle>
                  <CardDescription>{version.installed ? version.path : "Not installed on this Mac yet."}</CardDescription>
                </div>
                <Badge variant={version.active ? "success" : version.installed ? "default" : "warning"}>
                  {version.active ? "Active" : version.installed ? "Installed" : "Available"}
                </Badge>
              </div>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="rounded-2xl border border-slate-200 bg-slate-50/80 p-4 text-sm text-slate-600">
                {version.installed
                  ? "This version is ready for site routing and CLI use."
                  : "Install this runtime to make it available for websites and shell integration."}
              </div>
              <div className="flex flex-wrap gap-2">
                {version.installed ? (
                  <Button variant={version.active ? "secondary" : "default"} onClick={() => onActivate(version.version)}>
                    {version.active ? <CheckCircle2 className="h-4 w-4" /> : <Wand2 className="h-4 w-4" />}
                    {version.active ? "Already active" : "Activate"}
                  </Button>
                ) : (
                  <Button onClick={() => onInstall(version.version)}>
                    <Download className="h-4 w-4" />
                    Install
                  </Button>
                )}
              </div>
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  );
}
