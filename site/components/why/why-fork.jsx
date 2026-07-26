const WHY_ITEMS = [
  {
    q: 'Why a fork instead of upstream?',
    a: 'Ghostty does not ship a Windows app today. Winghostty keeps the Ghostty core and builds the Windows-native experience around it.',
  },
  {
    q: 'How close is it to Ghostty?',
    a: 'The terminal core is shared with Ghostty. The application runtime, windowing, settings, updater, and Windows integration are built for this fork.',
  },
  {
    q: 'Is it ready to use?',
    a: 'Public releases are available now. The project moves quickly, so review the current status and release notes before updating.',
  },
  {
    q: 'What platforms is this for?',
    a: 'Windows 10 and Windows 11 on x64 and ARM64. This fork is focused on shipping a native Windows app.',
  },
  {
    q: 'Anything to know before installing?',
    a: 'Yes. Release installers and Windows binaries are Authenticode-signed, but SmartScreen may still warn while reputation builds. Click More info, then Run anyway.',
  },
  {
    q: 'Does it phone home?',
    a: 'No telemetry or analytics. Update checks query GitHub Releases; download mode stages a verified signed installer and waits for your confirmation.',
  },
  {
    q: 'What is the accessibility status?',
    a: 'Windows UI Automation support is partial, not complete. Terminal text, focus, selection, the command palette, and native settings controls have coverage; broader per-widget and screen-reader validation is still in progress.',
  },
];

export function WhyFork() {
  return (
    <div className="wg-why-grid">
      {WHY_ITEMS.map((item) => (
        <article key={item.q} className="wg-why-item">
          <h3>{item.q}</h3>
          <p>{item.a}</p>
        </article>
      ))}
    </div>
  );
}
