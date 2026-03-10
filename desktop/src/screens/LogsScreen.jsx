import { SectionCard } from "../components/SectionCard";

export function LogsScreen({ content, onRefresh }) {
  return (
    <SectionCard kicker="Logs" title="FrankenPHP Output" actions={<button onClick={onRefresh}>Refresh</button>}>
      <pre className="log-viewer">{content || "No logs recorded yet."}</pre>
    </SectionCard>
  );
}

