import { useState } from "react";
import { Check, RotateCcw, Save } from "lucide-react";

import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { cn } from "../lib/utils";

const configFiles = [
  { key: "security", label: "Security", description: "HTTP security headers applied to every site" },
  { key: "php-app", label: "PHP App", description: "Caddy snippet for custom PHP websites" },
  { key: "laravel-app", label: "Laravel App", description: "Caddy snippet for Laravel projects" },
  { key: "php-ini", label: "php.ini", description: "PHP runtime settings (requires restart)" }
];

export function ConfigScreen({ configs, onSave, onReload }) {
  const [activeFile, setActiveFile] = useState("security");
  const [drafts, setDrafts] = useState({});
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  const currentContent = drafts[activeFile] ?? configs[activeFile] ?? "";
  const hasChanges = drafts[activeFile] != null && drafts[activeFile] !== (configs[activeFile] ?? "");

  const handleChange = (value) => {
    setDrafts((prev) => ({ ...prev, [activeFile]: value }));
    setSaved(false);
  };

  const handleSave = async () => {
    setSaving(true);
    try {
      await onSave(activeFile, currentContent);
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[activeFile];
        return next;
      });
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } finally {
      setSaving(false);
    }
  };

  const handleSaveAndReload = async () => {
    setSaving(true);
    try {
      await onSave(activeFile, currentContent);
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[activeFile];
        return next;
      });
      await onReload();
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } finally {
      setSaving(false);
    }
  };

  const handleReset = () => {
    setDrafts((prev) => {
      const next = { ...prev };
      delete next[activeFile];
      return next;
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-zinc-900">Configuration</h2>
        <div className="flex items-center gap-1.5">
          {hasChanges && (
            <Button size="sm" variant="ghost" onClick={handleReset} title="Discard changes">
              <RotateCcw className="h-3.5 w-3.5" />
              Discard
            </Button>
          )}
          {saved ? (
            <Button size="sm" variant="outline" disabled>
              <Check className="h-3.5 w-3.5 text-emerald-600" />
              Saved
            </Button>
          ) : (
            <>
              <Button size="sm" variant="outline" onClick={handleSave} disabled={!hasChanges || saving}>
                <Save className="h-3.5 w-3.5" />
                Save
              </Button>
              <Button size="sm" onClick={handleSaveAndReload} disabled={!hasChanges || saving}>
                <Save className="h-3.5 w-3.5" />
                Save & Reload
              </Button>
            </>
          )}
        </div>
      </div>

      <div className="flex gap-1.5 rounded-lg border border-zinc-200 bg-white p-1">
        {configFiles.map((file) => {
          const isActive = activeFile === file.key;
          const fileHasChanges = drafts[file.key] != null && drafts[file.key] !== (configs[file.key] ?? "");
          return (
            <button
              key={file.key}
              onClick={() => setActiveFile(file.key)}
              className={cn(
                "relative flex-1 rounded-md px-3 py-2 text-center text-[13px] font-medium transition-colors",
                isActive
                  ? "bg-zinc-900 text-white"
                  : "text-zinc-500 hover:bg-zinc-50 hover:text-zinc-900"
              )}
            >
              {file.label}
              {fileHasChanges && (
                <span className={cn(
                  "absolute top-1.5 right-1.5 h-1.5 w-1.5 rounded-full",
                  isActive ? "bg-amber-400" : "bg-amber-500"
                )} />
              )}
            </button>
          );
        })}
      </div>

      <Card>
        <CardHeader className="pb-2">
          <div className="flex items-center justify-between">
            <CardTitle className="text-sm">
              {configFiles.find((f) => f.key === activeFile)?.label}
            </CardTitle>
            <p className="text-xs text-zinc-400">
              {configFiles.find((f) => f.key === activeFile)?.description}
            </p>
          </div>
        </CardHeader>
        <CardContent>
          <textarea
            className="h-80 w-full resize-y rounded-md border border-zinc-200 bg-zinc-950 p-4 font-mono text-[13px] leading-relaxed text-zinc-100 outline-none focus:border-zinc-400"
            value={currentContent}
            onChange={(e) => handleChange(e.target.value)}
            spellCheck={false}
          />
        </CardContent>
      </Card>
    </div>
  );
}
