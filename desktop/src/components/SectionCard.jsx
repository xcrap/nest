export function SectionCard({ title, kicker, actions, children }) {
  return (
    <section className="section-card">
      <header className="section-card__header">
        <div>
          <p className="section-card__kicker">{kicker}</p>
          <h2>{title}</h2>
        </div>
        {actions ? <div className="section-card__actions">{actions}</div> : null}
      </header>
      {children}
    </section>
  );
}

