import { InstallCopiedIcon } from './install-copied-icon.jsx';
import { InstallCopyIcon } from './install-copy-icon.jsx';

const { useEffect, useRef, useState } = React;
const COPY_RESET_MS = 1400;

const INSTALL_METHODS = {
  scoop: {
    label: 'Scoop',
    cmd: 'scoop install winghostty/winghostty',
    copy: 'scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty\r\nscoop install winghostty/winghostty',
  },
  winget: {
    label: 'WinGet',
    cmd: 'winget install AmanThanvi.winghostty',
    copy: 'winget install AmanThanvi.winghostty',
  },
};

function writeClipboardText(text) {
  if (navigator.clipboard?.writeText) {
    return navigator.clipboard.writeText(text).catch(() => writeClipboardTextFallback(text));
  }

  return writeClipboardTextFallback(text);
}

function writeClipboardTextFallback(text) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  textarea.setAttribute('readonly', '');
  textarea.style.position = 'fixed';
  textarea.style.opacity = '0';
  document.body.appendChild(textarea);
  textarea.select();

  const copied = document.execCommand('copy');
  textarea.remove();

  if (copied) return Promise.resolve();
  return Promise.reject(new Error('Clipboard copy unavailable'));
}

export function InstallBlock() {
  const [method, setMethod] = useState('winget');
  const [copyStatus, setCopyStatus] = useState('idle');
  const copyTimerRef = useRef(null);
  const active = INSTALL_METHODS[method];
  const copied = copyStatus === 'copied';
  const copyFailed = copyStatus === 'failed';

  useEffect(() => () => {
    if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
  }, []);

  const setTemporaryCopyStatus = (status) => {
    if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
    setCopyStatus(status);
    copyTimerRef.current = setTimeout(() => {
      setCopyStatus('idle');
      copyTimerRef.current = null;
    }, COPY_RESET_MS);
  };

  const onCopy = () => {
    writeClipboardText(active.copy)
      .then(() => {
        setTemporaryCopyStatus('copied');
      })
      .catch(() => {
        setTemporaryCopyStatus('failed');
      });
  };

  const longestCmd = Object.values(INSTALL_METHODS).reduce(
    (longest, item) => (item.cmd.length > longest.length ? item.cmd : longest),
    '',
  );

  return (
    <div className="wg-install-lane">
      <div className="wg-install-panel">
        <div className="wg-install-frame">
          <svg
            className="wg-install-defs"
            aria-hidden="true"
            focusable="false"
            width="0"
            height="0"
          >
            <defs>
              <filter
                id="wg-goo"
                x="-15%"
                y="-15%"
                width="130%"
                height="130%"
                colorInterpolationFilters="sRGB"
              >
                <feGaussianBlur in="SourceGraphic" stdDeviation="4" result="blur" />
                <feColorMatrix
                  in="blur"
                  values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 22 -10"
                />
              </filter>
            </defs>
          </svg>
          <div className="wg-install-fluid" aria-hidden="true">
            <div className="wg-install-fluid__pill" />
            <div className="wg-install-fluid__tab" />
          </div>
          <div className="wg-install">
            <span className="wg-install__sizer" aria-hidden="true">{longestCmd}</span>
            <span className="wg-install__sigil">$</span>
            <code className="wg-install__command">{active.cmd}</code>
            <button
              type="button"
              className={`wg-install__copy${copied ? ' is-copied' : ''}${copyFailed ? ' is-failed' : ''}`}
              onClick={onCopy}
              aria-label={copied ? 'Copied' : copyFailed ? 'Copy failed' : 'Copy install command'}
            >
              {copied ? <InstallCopiedIcon /> : <InstallCopyIcon />}
            </button>
            <span className="wg-sr-only" aria-live="polite">
              {copied ? 'Copied' : copyFailed ? 'Copy failed' : ''}
            </span>
          </div>
          <fieldset className="wg-install-tabs">
            <legend className="wg-sr-only">Install method</legend>
            {Object.entries(INSTALL_METHODS).map(([key, item]) => (
              <button
                key={key}
                type="button"
                aria-pressed={method === key}
                className={method === key ? 'is-active' : undefined}
                onClick={() => {
                  setMethod(key);
                  setCopyStatus('idle');
                }}
              >
                {item.label}
              </button>
            ))}
          </fieldset>
        </div>
      </div>
    </div>
  );
}
