import { SectionCard } from "../components/SectionCard";

export function SettingsScreen({ doctorChecks, onBootstrap, onTrustLocalCA }) {
  return (
    <div className="screen-grid">
      <SectionCard
        kicker="First Run"
        title="Mac Setup"
        actions={
          <div className="inline-actions">
            <button onClick={onBootstrap}>Install .test Routing</button>
            <button className="button--ghost" onClick={onTrustLocalCA}>
              Trust Local HTTPS
            </button>
          </div>
        }
      >
        <p className="body-copy">
          `Install .test Routing` is the one-time machine bootstrap for local `.test` domains and port forwarding.
        </p>
        <p className="body-copy">
          `Trust Local HTTPS` should be run once after FrankenPHP has started at least one site, so your browser trusts `https://*.test`.
        </p>
      </SectionCard>

      <SectionCard kicker="Doctor" title="Fix Hints">
        <div className="doctor-list">
          {doctorChecks.map((check) => (
            <article className={`doctor-check doctor-check--${check.status}`} key={check.id}>
              <div>
                <strong>{check.id}</strong>
                <p>{check.fixHint || "No action required."}</p>
              </div>
              <span>{check.status}</span>
            </article>
          ))}
        </div>
      </SectionCard>
    </div>
  );
}
