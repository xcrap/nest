import { useState } from "react";
import { CheckCircle2, Download, Loader2, RefreshCw, Wand2 } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";

export function PHPVersionsScreen({ versions, onInstall, onActivate }) {
  return (
    <div className="space-y-4">
      <h2 className="text-lg font-semibold text-zinc-900">PHP runtimes</h2>

      <Card>
        <div className="divide-y divide-zinc-100">
          {versions.map((version) => (
            <PHPVersionRow
              key={version.version}
              version={version}
              onInstall={onInstall}
              onActivate={onActivate}
            />
          ))}
        </div>
      </Card>
    </div>
  );
}

function PHPVersionRow({ version, onInstall, onActivate }) {
  const [loading, setLoading] = useState(false);

  const handleAction = async (action) => {
    setLoading(true);
    try {
      await action(version.version);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex items-center gap-4 px-4 py-3.5">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <p className="text-sm font-semibold text-zinc-900">
            PHP {version.fullVersion || version.version}
          </p>
          {version.frankenphpVersion && (
            <span className="text-xs text-zinc-400">FrankenPHP v{version.frankenphpVersion}</span>
          )}
        </div>
        {version.installed && (
          <p className="mt-0.5 truncate font-mono text-xs text-zinc-400">{version.path}</p>
        )}
      </div>

      <div className="flex shrink-0 items-center gap-2">
        {version.installed && (
          <Button
            size="sm"
            variant="outline"
            onClick={() => handleAction(onInstall)}
            disabled={loading}
          >
            {loading ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
            Reinstall
          </Button>
        )}

        {version.installed ? (
          <Button
            size="sm"
            variant={version.active ? "outline" : "default"}
            onClick={() => handleAction(onActivate)}
            disabled={version.active || loading}
          >
            {version.active ? <CheckCircle2 className="h-3.5 w-3.5" /> : <Wand2 className="h-3.5 w-3.5" />}
            {version.active ? "Active" : "Activate"}
          </Button>
        ) : (
          <Button size="sm" onClick={() => handleAction(onInstall)} disabled={loading}>
            {loading ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Download className="h-3.5 w-3.5" />}
            Install
          </Button>
        )}

        <Badge variant={version.active ? "success" : version.installed ? "default" : "warning"}>
          {version.active ? "Active" : version.installed ? "Installed" : "Available"}
        </Badge>
      </div>
    </div>
  );
}
