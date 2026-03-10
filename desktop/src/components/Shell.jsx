export function Shell({ children }) {
  return (
    <div className="shell">
      <div className="shell__glow shell__glow--left" />
      <div className="shell__glow shell__glow--right" />
      {children}
    </div>
  );
}

