import { useMemo, useState } from "react";
import { Download, ExternalLink, FolderSearch2, Pencil, Plus, Power, PowerOff, Trash2, Upload } from "lucide-react";

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

const defaultForm = {
  name: "",
  domain: "",
  rootPath: "",
  documentRoot: "public"
};

export function SitesScreen({ sites, onCreate, onUpdate, onDelete, onStart, onStop, onPickDirectory, onOpenUrl, onExport, onImport }) {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingSiteId, setEditingSiteId] = useState(null);
  const [form, setForm] = useState(defaultForm);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const sortedSites = useMemo(
    () =>
      [...sites].sort(
        (left, right) =>
          left.name.localeCompare(right.name, undefined, { sensitivity: "base" }) ||
          left.domain.localeCompare(right.domain, undefined, { sensitivity: "base" })
      ),
    [sites]
  );

  const openCreate = () => {
    setEditingSiteId(null);
    setForm(defaultForm);
    setDialogOpen(true);
  };

  const openEdit = (site) => {
    setEditingSiteId(site.id);
    setForm({
      name: site.name,
      domain: site.domain,
      rootPath: site.rootPath,
      documentRoot: site.documentRoot || "public"
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
        <div className="flex items-center gap-1.5">
          <Button size="sm" variant="outline" onClick={onImport}>
            <Upload className="h-3.5 w-3.5" />
            Import
          </Button>
          <Button size="sm" variant="outline" onClick={onExport} disabled={sites.length === 0}>
            <Download className="h-3.5 w-3.5" />
            Export
          </Button>
          <Button size="sm" onClick={openCreate}>
            <Plus className="h-3.5 w-3.5" />
            Add site
          </Button>
        </div>
      </div>

      {sortedSites.length === 0 && (
        <Card>
          <CardContent className="py-12 text-center text-sm text-zinc-400">
            No sites yet. Add your first project to get started.
          </CardContent>
        </Card>
      )}

      <Card>
        <div className="divide-y divide-zinc-100">
          {sortedSites.map((site) => (
            <div key={site.id} className="flex items-center gap-3 px-4 py-3">
              <span className={`h-2 w-2 shrink-0 rounded-full ${site.status === "running" ? "bg-emerald-500" : "bg-zinc-300"}`} title={site.status} />

              <div className="w-36 min-w-0 shrink-0">
                <p className="truncate text-sm font-medium text-zinc-900">{site.name}</p>
                <p className="truncate text-[13px] text-zinc-400">{site.domain}</p>
              </div>

              <p className="min-w-0 flex-1 truncate rounded bg-zinc-50 px-2.5 py-1 font-mono text-xs text-zinc-500">
                {site.rootPath}
              </p>

              <div className="flex shrink-0 items-center gap-1.5">
                <Badge variant="success">HTTPS</Badge>
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
                <Button size="iconSm" variant="ghost" onClick={() => onOpenUrl(`https://${site.domain}`)} title="Open in browser">
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
      />
    </div>
  );
}

function SiteDialog({ open, onClose, isEditing, form, onSetForm, onSubmit, onPickDirectory, isSubmitting }) {
  return (
    <Dialog open={open} onOpenChange={(nextOpen) => (nextOpen ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEditing ? "Edit site" : "Add site"}</DialogTitle>
          <DialogDescription>Configure the domain, project folder, and runtime.</DialogDescription>
        </DialogHeader>

        <form className="space-y-4" onSubmit={onSubmit}>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Name">
              <Input
                value={form.name}
                onChange={(e) => onSetForm((current) => ({ ...current, name: e.target.value }))}
                placeholder="My project"
                required
              />
            </Field>
            <Field label="Domain">
              <Input
                value={form.domain}
                onChange={(e) => onSetForm((current) => ({ ...current, domain: e.target.value }))}
                placeholder="project.test"
                required
              />
            </Field>
          </div>

          <Field label="Project folder">
            <div className="flex gap-2">
              <Input
                className="flex-1"
                value={form.rootPath}
                onChange={(e) => onSetForm((current) => ({ ...current, rootPath: e.target.value }))}
                placeholder="/Users/you/Sites/project"
                required
              />
              <Button onClick={onPickDirectory} type="button" variant="outline" size="sm">
                <FolderSearch2 className="h-3.5 w-3.5" />
                Browse
              </Button>
            </div>
          </Field>

          <Field label="Document root">
            <Input
              value={form.documentRoot}
              onChange={(e) => onSetForm((current) => ({ ...current, documentRoot: e.target.value }))}
              placeholder="public"
              required
            />
            <p className="text-xs text-zinc-400">Use `public` for `/public`, or `.` to serve the project folder directly.</p>
          </Field>

          <div className="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-[13px] text-emerald-800">
            Nest serves sites over HTTPS using the shared local certificate setup.
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
