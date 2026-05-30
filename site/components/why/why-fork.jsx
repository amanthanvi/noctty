const WHY_ITEMS = [
  {
    q: 'Why a fork instead of upstream?',
    a: 'Ghostty does not ship a Windows app today. Winghostty keeps the Ghostty core and builds the Windows-native experience around it.',
  },
  {
    q: 'How close is it to Ghostty?',
    a: 'Close where it matters: the terminal core is shared, while the app layer around it is purpose-built for Windows.',
  },
  {
    q: 'Is it ready to use?',
    a: 'Winghostty is young, with first public releases on April 16, 2026, but it is already usable if you are comfortable running a fast-moving project.',
  },
  {
    q: 'What platforms is this for?',
    a: 'Windows 10 and Windows 11 on x64 and ARM64. This fork is focused on shipping a native Windows app.',
  },
  {
    q: 'Anything to know before installing?',
    a: 'Yes. Installers are self-signed, not signed by a public CA, so SmartScreen may still warn on first run. Click More info, then Run anyway.',
  },
  {
    q: 'Does it phone home?',
    a: 'No telemetry or analytics. The updater only checks GitHub for new releases and stays notify-only.',
  },
];

export function WhyFork() {
  return (
    <div className="wg-why-grid">
      {WHY_ITEMS.map((item, idx) => (
        <div key={item.q} className="wg-why-item">
          <span className="wg-why-item__index">{String(idx + 1).padStart(2, '0')}</span>
          <div>
            <h2>{item.q}</h2>
            <p>{item.a}</p>
          </div>
        </div>
      ))}
    </div>
  );
}
