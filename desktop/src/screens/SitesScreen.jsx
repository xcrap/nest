import { useMemo, useState } from "react";
import { ExternalLink, FolderSearch2, Pencil, Plus, Power, PowerOff, Shield, Trash2 } from "lucide-react";

import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "../components/ui/card";
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
    if (versions.length > 0) {
      return versions;
    }
    return [{ version: "8.5", installed: false, active: false, path: "" }];
  }, [versions]);

  const openCreate = () => {
    setEditingSiteId(null);
    setForm({
      ...defaultForm,
      phpVersion: phpOptions.find((version) => version.active)?.version || phpOptions[0]?.version || "8.5"
    });
    setDialogOpen(true);
  };

  const openEdit = (site) => {
    setEditingSiteId(site.id);
    setForm({
      name: site.name,
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
    if (path) {
      setForm((current) => ({ ...current, rootPath: path }));
    }
  };

  const deleteSite = async (site) => {
    if (!window.confirm(`Delete ${site.domain}?`)) {
      return;
    }
    await onDelete(site.id);
  };

  return (
    <div className="space-y-6">
      <Card>
        <CardContent className="flex flex-col gap-5 px-6 py-6 lg:flex-row lg:items-end lg:justify-between lg:px-8">
          <div className="space-y-2">
            <Badge variant="accent">Sites</Badge>
            <h2 className="text-3xl font-semibold tracking-tight text-slate-950">Map projects to clean local domains.</h2>
            <p className="max-w-2xl text-sm leading-6 text-slate-600">
              Register a project root, pick the active PHP runtime, and edit site settings without touching config files.
            </p>
          </div>
          <Button onClick={openCreate}>
            <Plus className="h-4 w-4" />
            Add website
          </Button>
        </CardContent>
      </Card>

      <div className="grid gap-4 xl:grid-cols-2">
        {sites.length === 0 ? (
          <Card className="xl:col-span-2">
            <CardContent className="px-6 py-16 text-center text-sm text-slate-500">
              No websites yet. Add your first project and Nest will generate routing and TLS around it.
            </CardContent>
          </Card>
        ) : null}

        {sites.map((site) => (
          <Card key={site.id} className="border-slate-200/90">
            <CardHeader className="gap-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="space-y-1">
                  <CardTitle className="text-xl">{site.name}</CardTitle>
                  <CardDescription className="text-base text-slate-500">{site.domain}</CardDescription>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Badge variant={site.status === "running" ? "success" : "default"}>{site.status}</Badge>
                  <Badge variant="accent">PHP {site.phpVersion}</Badge>
                  <Badge variant={site.httpsEnabled ? "success" : "warning"}>{site.httpsEnabled ? "HTTPS" : "HTTP"}</Badge>
                </div>
              </div>
            </CardHeader>
            <CardContent className="space-y-5">
              <div className="rounded-2xl border border-slate-200 bg-slate-50/80 p-4 text-sm text-slate-600">
                <p className="font-medium text-slate-900">Project root</p>
                <p className="mt-2 break-all">{site.rootPath}</p>
              </div>

              <div className="flex flex-wrap gap-2">
                {site.status === "running" ? (
                  <Button variant="secondary" onClick={() => onStop(site.id)}>
                    <PowerOff className="h-4 w-4" />
                    Stop
                  </Button>
                ) : (
                  <Button onClick={() => onStart(site.id)}>
                    <Power className="h-4 w-4" />
                    Start
                  </Button>
                )}
                <Button variant="outline" onClick={() => openEdit(site)}>
                  <Pencil className="h-4 w-4" />
                  Edit
                </Button>
                <Button variant="outline" onClick={() => onOpenUrl(site.httpsEnabled ? `https://${site.domain}` : `http://${site.domain}`)}>
                  <ExternalLink className="h-4 w-4" />
                  Open
                </Button>
                <Button variant="ghost" onClick={() => deleteSite(site)}>
                  <Trash2 className="h-4 w-4" />
                  Delete
                </Button>
              </div>

              <div className="flex items-center justify-between text-xs text-slate-400">
                <span>Updated {formatRelativeDate(site.updatedAt)}</span>
                <span>ID {site.id}</span>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

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
          <DialogTitle>{isEditing ? "Edit website" : "Add website"}</DialogTitle>
          <DialogDescription>Choose the project folder, domain, runtime, and TLS preference for this site.</DialogDescription>
        </DialogHeader>

        <form className="space-y-5" onSubmit={onSubmit}>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Name">
              <Input
                value={form.name}
                onChange={(event) => onSetForm((current) => ({ ...current, name: event.target.value }))}
                placeholder="Marketing site"
                required
              />
            </Field>
            <Field label="Domain">
              <Input
                value={form.domain}
                onChange={(event) => onSetForm((current) => ({ ...current, domain: event.target.value }))}
                placeholder="marketing.test"
                required
              />
            </Field>
          </div>

          <Field label="Project root">
            <div className="flex gap-3">
              <Input
                className="flex-1"
                value={form.rootPath}
                onChange={(event) => onSetForm((current) => ({ ...current, rootPath: event.target.value }))}
                placeholder="/Users/you/Sites/project/public"
                required
              />
              <Button onClick={onPickDirectory} type="button" variant="secondary">
                <FolderSearch2 className="h-4 w-4" />
                Choose folder
              </Button>
            </div>
          </Field>

          <div className="grid gap-4 sm:grid-cols-[minmax(0,1fr)_220px]">
            <Field label="PHP version">
              <Select value={form.phpVersion} onChange={(event) => onSetForm((current) => ({ ...current, phpVersion: event.target.value }))}>
                {versions.map((version) => (
                  <option key={version.version} value={version.version}>
                    PHP {version.version}
                    {version.active ? " • active" : ""}
                    {version.installed ? "" : " • not installed"}
                  </option>
                ))}
              </Select>
            </Field>

            <div className="rounded-2xl border border-slate-200 bg-slate-50/70 px-4 py-3">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <Label className="flex items-center gap-2 text-slate-900">
                    <Shield className="h-4 w-4 text-emerald-600" />
                    HTTPS
                  </Label>
                  <p className="mt-1 text-xs text-slate-500">Issue local certificates for this domain.</p>
                </div>
                <Switch
                  checked={form.httpsEnabled}
                  onCheckedChange={(checked) => onSetForm((current) => ({ ...current, httpsEnabled: checked }))}
                />
              </div>
            </div>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isEditing ? "Save changes" : "Create website"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function Field({ label, children }) {
  return (
    <div className="space-y-2">
      <Label>{label}</Label>
      {children}
    </div>
  );
}
