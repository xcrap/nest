import { useState } from "react";
import { CheckCircle2, Download, Loader2, RotateCcw, RefreshCw, Wand2 } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";

export function PHPVersionsScreen({
  versions,
  composerRuntime,
  onInstall,
  onActivate,
  onInstallComposer,
  onCheckComposerUpdates,
  onUpdateComposer,
  onRollbackComposer
}) {
  return (
    <div className="space-y-4">
      <h2 className="text-lg font-semibold text-zinc-900">PHP runtimes</h2>

      <ComposerCard
        runtime={composerRuntime}
        onInstallComposer={onInstallComposer}
        onCheckComposerUpdates={onCheckComposerUpdates}
        onUpdateComposer={onUpdateComposer}
        onRollbackComposer={onRollbackComposer}
      />

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

function ComposerCard({ runtime, onInstallComposer, onCheckComposerUpdates, onUpdateComposer, onRollbackComposer }) {
  const [loading, setLoading] = useState(false);

  const run = async (action) => {
    setLoading(true);
    try {
      await action();
    } finally {
      setLoading(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Composer</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="rounded-md border border-zinc-100 bg-zinc-50 p-3 text-[13px]">
          <div className="flex items-center justify-between gap-3">
            <div>
              <p className="text-sm font-medium text-zinc-900">
                {runtime?.installed ? `Composer ${runtime.installedVersion || "installed"}` : "Composer not installed"}
              </p>
              <p className="mt-0.5 text-zinc-500">
                {runtime?.installed
                  ? "Nest manages composer.phar, the wrapper, and rollback backup."
                  : "Install the official Composer phar and a Nest-managed wrapper."}
              </p>
            </div>
            <Badge variant={runtime?.installed ? "success" : "warning"}>
              {runtime?.installed ? "Installed" : "Missing"}
            </Badge>
          </div>
          {runtime?.sourceURL && (
            <p className="mt-2 truncate font-mono text-xs text-zinc-400">{runtime.sourceURL}</p>
          )}
          {runtime?.lastError && (
            <p className="mt-2 text-xs text-red-600">{runtime.lastError}</p>
          )}
          {runtime?.updateAvailable && (
            <p className="mt-2 text-xs font-medium text-amber-700">
              Update available{runtime.latestVersion ? `: ${runtime.latestVersion}` : ""}.
            </p>
          )}
        </div>

        <div className="flex flex-wrap gap-2">
          {!runtime?.installed ? (
            <Button size="sm" onClick={() => run(onInstallComposer)} disabled={loading}>
              {loading ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Download className="h-3.5 w-3.5" />}
              Install Composer
            </Button>
          ) : (
            <>
              <Button size="sm" variant="outline" onClick={() => run(onCheckComposerUpdates)} disabled={loading}>
                {loading ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
                Check updates
              </Button>
              <Button
                size="sm"
                onClick={() => run(onUpdateComposer)}
                disabled={loading || (runtime?.latestChecksum && !runtime?.updateAvailable)}
              >
                {loading ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Download className="h-3.5 w-3.5" />}
                Update
              </Button>
              <Button
                size="sm"
                variant="outline"
                onClick={() => run(onRollbackComposer)}
                disabled={loading || !runtime?.backupAvailable}
              >
                {loading ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RotateCcw className="h-3.5 w-3.5" />}
                Rollback
              </Button>
            </>
          )}
        </div>
      </CardContent>
    </Card>
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

        {!version.installed && (
          <Badge variant="warning">Available</Badge>
        )}
      </div>
    </div>
  );
}
