import { SectionCard } from "../components/SectionCard";

export function DashboardScreen({ sites, doctorChecks, serviceStatus, onStartServices, onStopServices, onReloadServices }) {
  const runningSites = sites.filter((site) => site.status === "running").length;
  const warnings = doctorChecks.filter((check) => check.status !== "pass").length;

  return (
    <div className="screen-grid screen-grid--dashboard">
      <SectionCard
        kicker="Core Engine"
        title="Runtime Control"
        actions={
          <div className="inline-actions">
            <button onClick={onStartServices}>Start</button>
            <button onClick={onReloadServices}>Reload</button>
            <button className="button--ghost" onClick={onStopServices}>
              Stop
            </button>
          </div>
        }
      >
        <div className="metric-row">
          <div className="metric">
            <span className="metric__label">FrankenPHP</span>
            <strong>{serviceStatus}</strong>
          </div>
          <div className="metric">
            <span className="metric__label">Running Sites</span>
            <strong>{runningSites}</strong>
          </div>
          <div className="metric">
            <span className="metric__label">Doctor Alerts</span>
            <strong>{warnings}</strong>
          </div>
        </div>
      </SectionCard>

      <SectionCard kicker="Migration" title="Herd Conflict Guard">
        <p className="body-copy">
          Nest assumes Herd is fully quit during migration. The doctor panel below will flag any live Herd process so the web stack does not fight over local routing.
        </p>
      </SectionCard>

      <SectionCard kicker="Doctor" title="System Health">
        <div className="doctor-list">
          {doctorChecks.map((check) => (
            <article className={`doctor-check doctor-check--${check.status}`} key={check.id}>
              <div>
                <strong>{check.id}</strong>
                <p>{check.message}</p>
              </div>
              <span>{check.status}</span>
            </article>
          ))}
        </div>
      </SectionCard>
    </div>
  );
}

