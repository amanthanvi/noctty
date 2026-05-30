export function TerminalLine({ prompt, text, cursor }) {
  return (
    <p>
      <span className="wg-terminal__prompt">{prompt}</span>
      <span className="wg-terminal__live">
        {text}
        {cursor && <span className="wg-caret" aria-hidden="true">▋</span>}
      </span>
    </p>
  );
}
