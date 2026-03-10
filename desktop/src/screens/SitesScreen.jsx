import { useState } from "react";

import { SectionCard } from "../components/SectionCard";

const initialForm = {
  name: "",
  domain: "",
  rootPath: "",
  phpVersion: "8.5",
  httpsEnabled: true
};

export function SitesScreen({ sites, onCreate, onDelete, onStart, onStop }) {
  const [form, setForm] = useState(initialForm);

  const submit = async (event) => {
    event.preventDefault();
    await onCreate(form);
    setForm(initialForm);
  };

  return (
    <div className="screen-grid">
      <SectionCard kicker="Sites" title="Register Local Website">
        <form className="site-form" onSubmit={submit}>
          <label>
            Name
            <input value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} required />
          </label>
          <label>
            Domain
            <input value={form.domain} onChange={(event) => setForm({ ...form, domain: event.target.value })} placeholder="project.test" required />
          </label>
          <label>
            Root Path
            <input value={form.rootPath} onChange={(event) => setForm({ ...form, rootPath: event.target.value })} placeholder="~/Sites/project/public" required />
          </label>
          <label>
            PHP Version
            <input value={form.phpVersion} onChange={(event) => setForm({ ...form, phpVersion: event.target.value })} />
          </label>
          <label className="checkbox">
            <input
              checked={form.httpsEnabled}
              onChange={(event) => setForm({ ...form, httpsEnabled: event.target.checked })}
              type="checkbox"
            />
            Enable HTTPS
          </label>
          <button type="submit">Add Site</button>
        </form>
      </SectionCard>

      <SectionCard kicker="Registry" title="Managed Websites">
        <div className="site-list">
          {sites.map((site) => (
            <article className="site-card" key={site.id}>
              <div>
                <h3>{site.domain}</h3>
                <p>{site.rootPath}</p>
                <span>{site.phpVersion}</span>
              </div>
              <div className="inline-actions">
                {site.status === "running" ? (
                  <button className="button--ghost" onClick={() => onStop(site.id)}>
                    Stop
                  </button>
                ) : (
                  <button onClick={() => onStart(site.id)}>Start</button>
                )}
                <button className="button--ghost" onClick={() => onDelete(site.id)}>
                  Delete
                </button>
              </div>
            </article>
          ))}
          {sites.length === 0 ? <p className="empty-state">No local sites registered yet.</p> : null}
        </div>
      </SectionCard>
    </div>
  );
}
