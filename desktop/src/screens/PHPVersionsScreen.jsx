import { CheckCircle2, Download, Wand2 } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card } from "../components/ui/card";

export function PHPVersionsScreen({ versions, onInstall, onActivate }) {
  return (
    <div className="space-y-4">
      <h2 className="text-lg font-semibold text-zinc-900">PHP runtimes</h2>

      <div className="grid gap-3 lg:grid-cols-2">
        {versions.map((version) => (
          <Card
            key={version.version}
            className={version.active ? "border-blue-200 ring-1 ring-blue-100" : undefined}
          >
            <div className="space-y-3 p-4">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="text-sm font-semibold text-zinc-900">PHP {version.version}</p>
                  <p className="text-[13px] text-zinc-500">
                    {version.installed ? version.path : "Not installed"}
                  </p>
                </div>
                <Badge variant={version.active ? "success" : version.installed ? "default" : "warning"}>
                  {version.active ? "Active" : version.installed ? "Installed" : "Available"}
                </Badge>
              </div>

              <div className="flex gap-2">
                {version.installed ? (
                  <Button
                    size="sm"
                    variant={version.active ? "outline" : "default"}
                    onClick={() => onActivate(version.version)}
                    disabled={version.active}
                  >
                    {version.active ? <CheckCircle2 className="h-3.5 w-3.5" /> : <Wand2 className="h-3.5 w-3.5" />}
                    {version.active ? "Active" : "Activate"}
                  </Button>
                ) : (
                  <Button size="sm" onClick={() => onInstall(version.version)}>
                    <Download className="h-3.5 w-3.5" />
                    Install
                  </Button>
                )}
              </div>
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
}
