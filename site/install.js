// Copies the Scoop install command from the hero.

const COPY_RESET_MS = 1400;
const INSTALL_COMMAND =
  'scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty\r\nscoop install noctty/noctty';

function writeClipboardTextFallback(text) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  textarea.setAttribute('readonly', '');
  textarea.setAttribute('aria-hidden', 'true');
  textarea.tabIndex = -1;
  textarea.className = 'nc-clipboard-stage';
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

function writeClipboardText(text) {
  if (navigator.clipboard?.writeText) {
    return navigator.clipboard.writeText(text).catch(() => writeClipboardTextFallback(text));
  }
  return writeClipboardTextFallback(text);
}

const copyButton = document.getElementById('nc-install-copy');
const status = document.getElementById('nc-install-status');

if (copyButton && status) {
  let copyTimer = null;

  function setCopyState(state) {
    if (copyTimer !== null) {
      clearTimeout(copyTimer);
      copyTimer = null;
    }
    copyButton.classList.toggle('is-copied', state === 'copied');
    copyButton.classList.toggle('is-failed', state === 'failed');
    const label =
      state === 'copied' ? 'Copied' : state === 'failed' ? 'Copy failed' : 'Copy install command';
    copyButton.setAttribute('aria-label', label);
    status.textContent = state === 'idle' ? '' : label;
    if (state !== 'idle') {
      copyTimer = setTimeout(() => {
        copyTimer = null;
        setCopyState('idle');
      }, COPY_RESET_MS);
    }
  }

  copyButton.addEventListener('click', () => {
    writeClipboardText(INSTALL_COMMAND)
      .then(() => setCopyState('copied'))
      .catch(() => setCopyState('failed'));
  });
}
