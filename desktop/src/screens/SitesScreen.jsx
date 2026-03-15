import { useMemo, useState } from "react";
import { ExternalLink, FolderSearch2, Pencil, Plus, Power, PowerOff, Shield, Trash2 } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent } from "../components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from "../components/ui/dialog";
import { Input } from "../components/ui/input";
import { Label } from "../components/ui/label";
import { Select } from "../components/ui/select";
import { Switch } from "../components/ui/switch";
import { formatRelativeDate } from "../lib/utils";

const defaultForm = {
  name: "",
  type: "php",
  domain: "",
  rootPath: "",
  phpVersion: "8.5",
  httpsEnabled: true
};

export function SitesScreen({ sites, versions, onCreate, onUpdate, onDelete, onStart, onStop, onPickDirectory, onOpenUrl }) {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingSiteId, setEditingSiteId] = useState(null);
  const [form, setForm] = useState(defaultForm);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const phpOptions = useMemo(() => {
    if (versions.length > 0) return versions;
    return [{ version: "8.5", installed: false, active: false, path: "" }];
  }, [versions]);

  const openCreate = () => {
    setEditingSiteId(null);
    setForm({
      ...defaultForm,
      phpVersion: phpOptions.find((v) => v.active)?.version || phpOptions[0]?.version || "8.5"
    });
    setDialogOpen(true);
  };

  const openEdit = (site) => {
    setEditingSiteId(site.id);
    setForm({
      name: site.name,
      type: site.type || "php",
      domain: site.domain,
      rootPath: site.rootPath,
      phpVersion: site.phpVersion,
      httpsEnabled: site.httpsEnabled
    });
    setDialogOpen(true);
  };

  const handleSubmit = async (event) => {
    event.preventDefault();
    setIsSubmitting(true);
    try {
      if (editingSiteId) {
        await onUpdate(editingSiteId, form);
      } else {
        await onCreate(form);
      }
      setDialogOpen(false);
      setEditingSiteId(null);
      setForm(defaultForm);
    } finally {
      setIsSubmitting(false);
    }
  };

  const pickDirectory = async () => {
    const path = await onPickDirectory();
    if (path) setForm((current) => ({ ...current, rootPath: path }));
  };

  const deleteSite = async (site) => {
    if (!window.confirm(`Delete ${site.domain}?`)) return;
    await onDelete(site.id);
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-zinc-900">Sites</h2>
        <Button size="sm" onClick={openCreate}>
          <Plus className="h-3.5 w-3.5" />
          Add site
        </Button>
      </div>

      {sites.length === 0 && (
        <Card>
          <CardContent className="py-12 text-center text-sm text-zinc-400">
            No sites yet. Add your first project to get started.
          </CardContent>
        </Card>
      )}

      <Card>
        <div className="divide-y divide-zinc-100">
          {sites.map((site) => (
            <div key={site.id} className="flex items-center gap-4 px-4 py-3">
              <div className="w-36 min-w-0 shrink-0">
                <p className="truncate text-sm font-medium text-zinc-900">{site.name}</p>
                <p className="truncate text-[13px] text-zinc-400">{site.domain}</p>
              </div>

              <p className="min-w-0 flex-1 truncate rounded bg-zinc-50 px-2.5 py-1 font-mono text-xs text-zinc-500">
                {site.rootPath}
              </p>

              <div className="flex shrink-0 items-center gap-1.5">
                <Badge variant={site.status === "running" ? "success" : "default"}>{site.status}</Badge>
                <Badge variant={site.type === "laravel" ? "accent" : "default"}>
                  {site.type === "laravel" ? "Laravel" : "PHP"}
                </Badge>
                <Badge variant="accent">PHP {site.phpVersion}</Badge>
                <Badge variant={site.httpsEnabled ? "success" : "warning"}>
                  {site.httpsEnabled ? "HTTPS" : "HTTP"}
                </Badge>
              </div>

              <div className="flex shrink-0 items-center gap-0.5">
                {site.status === "running" ? (
                  <Button size="iconSm" variant="ghost" onClick={() => onStop(site.id)} title="Stop">
                    <PowerOff className="h-3.5 w-3.5" />
                  </Button>
                ) : (
                  <Button size="iconSm" variant="ghost" onClick={() => onStart(site.id)} title="Start">
                    <Power className="h-3.5 w-3.5" />
                  </Button>
                )}
                <Button size="iconSm" variant="ghost" onClick={() => openEdit(site)} title="Edit">
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <Button size="iconSm" variant="ghost" onClick={() => onOpenUrl(site.httpsEnabled ? `https://${site.domain}` : `http://${site.domain}`)} title="Open in browser">
                  <ExternalLink className="h-3.5 w-3.5" />
                </Button>
                <Button size="iconSm" variant="ghost" onClick={() => deleteSite(site)} title="Delete">
                  <Trash2 className="h-3.5 w-3.5 text-zinc-400" />
                </Button>
              </div>
            </div>
          ))}
        </div>
      </Card>

      <SiteDialog
        form={form}
        isSubmitting={isSubmitting}
        isEditing={Boolean(editingSiteId)}
        onClose={() => {
          setDialogOpen(false);
          setEditingSiteId(null);
        }}
        onPickDirectory={pickDirectory}
        onSetForm={setForm}
        onSubmit={handleSubmit}
        open={dialogOpen}
        versions={phpOptions}
      />
    </div>
  );
}

function SiteDialog({ open, onClose, isEditing, form, onSetForm, onSubmit, onPickDirectory, versions, isSubmitting }) {
  return (
    <Dialog open={open} onOpenChange={(nextOpen) => (nextOpen ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEditing ? "Edit site" : "Add site"}</DialogTitle>
          <DialogDescription>Configure the domain, project folder, and runtime.</DialogDescription>
        </DialogHeader>

        <form className="space-y-4" onSubmit={onSubmit}>
          <div className="grid gap-3 sm:grid-cols-3">
            <Field label="Name">
              <Input
                value={form.name}
                onChange={(e) => onSetForm((c) => ({ ...c, name: e.target.value }))}
                placeholder="My project"
                required
              />
            </Field>
            <Field label="Type">
              <Select value={form.type} onChange={(e) => onSetForm((c) => ({ ...c, type: e.target.value }))}>
                <option value="php">PHP</option>
                <option value="laravel">Laravel</option>
              </Select>
            </Field>
            <Field label="Domain">
              <Input
                value={form.domain}
                onChange={(e) => onSetForm((c) => ({ ...c, domain: e.target.value }))}
                placeholder="project.test"
                required
              />
            </Field>
          </div>

          <Field label="Project root">
            <div className="flex gap-2">
              <Input
                className="flex-1"
                value={form.rootPath}
                onChange={(e) => onSetForm((c) => ({ ...c, rootPath: e.target.value }))}
                placeholder="/Users/you/Sites/project/public"
                required
              />
              <Button onClick={onPickDirectory} type="button" variant="outline" size="sm">
                <FolderSearch2 className="h-3.5 w-3.5" />
                Browse
              </Button>
            </div>
          </Field>

          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="PHP version">
              <Select value={form.phpVersion} onChange={(e) => onSetForm((c) => ({ ...c, phpVersion: e.target.value }))}>
                {versions.map((v) => (
                  <option key={v.version} value={v.version}>
                    PHP {v.version}{v.active ? " (active)" : ""}{v.installed ? "" : " (not installed)"}
                  </option>
                ))}
              </Select>
            </Field>

            <div className="flex items-center justify-between gap-3 rounded-md border border-zinc-200 px-3 py-2">
              <div>
                <Label className="flex items-center gap-1.5">
                  <Shield className="h-3.5 w-3.5 text-emerald-600" />
                  HTTPS
                </Label>
                <p className="mt-0.5 text-xs text-zinc-400">Local certificates</p>
              </div>
              <Switch
                checked={form.httpsEnabled}
                onCheckedChange={(checked) => onSetForm((c) => ({ ...c, httpsEnabled: checked }))}
              />
            </div>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={isSubmitting}>
              {isEditing ? "Save" : "Create"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function Field({ label, children }) {
  return (
    <div className="space-y-1.5">
      <Label>{label}</Label>
      {children}
    </div>
  );
}
