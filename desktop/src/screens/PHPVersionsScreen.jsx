import { SectionCard } from "../components/SectionCard";

export function PHPVersionsScreen({ versions, onInstall, onActivate }) {
  return (
    <SectionCard kicker="Runtimes" title="PHP Versions">
      <div className="php-grid">
        {versions.map((version) => (
          <article className={`php-card ${version.active ? "php-card--active" : ""}`} key={version.version}>
            <div>
              <h3>PHP {version.version}</h3>
              <p>{version.installed ? version.path : "Not installed yet"}</p>
            </div>
            <div className="inline-actions">
              {version.installed ? (
                <button className="button--ghost" onClick={() => onActivate(version.version)}>
                  {version.active ? "Active" : "Activate"}
                </button>
              ) : (
                <button onClick={() => onInstall(version.version)}>Install</button>
              )}
            </div>
          </article>
        ))}
      </div>
    </SectionCard>
  );
}

