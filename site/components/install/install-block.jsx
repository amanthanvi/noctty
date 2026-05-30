import { InstallCopiedIcon } from './install-copied-icon.jsx';
import { InstallCopyIcon } from './install-copy-icon.jsx';

const { useEffect, useRef, useState } = React;
const COPY_RESET_MS = 1400;

const INSTALL_METHODS = {
  scoop: {
    label: 'Scoop',
    cmd: 'scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty; scoop install winghostty/winghostty',
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
  textarea.setAttribute('aria-hidden', 'true');
  textarea.tabIndex = -1;
  textarea.style.position = 'fixed';
  textarea.style.top = '-1000px';
  textarea.style.left = '-1000px';
  textarea.style.opacity = '0';
  document.body.appendChild(textarea);

  let copied = false;
  try {
    textarea.select();
    copied = document.execCommand('copy');
  } catch (e) {
    return Promise.reject(e);
  } finally {
    textarea.remove();
  }

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

  const clearCopyTimer = () => {
    if (!copyTimerRef.current) return;
    clearTimeout(copyTimerRef.current);
    copyTimerRef.current = null;
  };

  const setTemporaryCopyStatus = (status) => {
    clearCopyTimer();
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

  return (
    <div className="wg-install-lane">
      <div className="wg-install-panel">
        <div className="wg-install-frame">
          <div className="wg-install-fluid" aria-hidden="true">
            <div className="wg-install-fluid__pill" />
            <div className="wg-install-fluid__tab" />
          </div>
          <div className="wg-install">
            <span className="wg-install__sigil">$</span>
            <code className="wg-install__command" title={active.cmd}>{active.cmd}</code>
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
                  clearCopyTimer();
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
