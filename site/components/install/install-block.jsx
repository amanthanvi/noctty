import { InstallCopiedIcon } from './install-copied-icon.jsx';
import { InstallCopyIcon } from './install-copy-icon.jsx';

const { useState } = React;

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

export function InstallBlock() {
  const [method, setMethod] = useState('winget');
  const [copied, setCopied] = useState(false);
  const active = INSTALL_METHODS[method];

  const onCopy = () => {
    navigator.clipboard?.writeText(active.copy).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    });
  };

  const longestCmd = INSTALL_METHODS.winget.cmd;

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
            <span className="wg-install__sigil">{String.fromCharCode(36)}</span>
            <code className="wg-install__command">{active.cmd}</code>
            <button
              type="button"
              className={`wg-install__copy${copied ? ' is-copied' : ''}`}
              onClick={onCopy}
              aria-label={copied ? 'Copied' : 'Copy install command'}
            >
              {copied ? <InstallCopiedIcon /> : <InstallCopyIcon />}
            </button>
          </div>
          <div className="wg-install-tabs" role="tablist" aria-label="Install method">
            {Object.entries(INSTALL_METHODS).map(([key, item]) => (
              <button
                key={key}
                type="button"
                role="tab"
                aria-selected={method === key}
                className={method === key ? 'is-active' : undefined}
                onClick={() => {
                  setMethod(key);
                  setCopied(false);
                }}
              >
                {item.label}
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
