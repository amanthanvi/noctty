// Copies the install commands. The copied text comes from these constants,
// not the page, so the clipboard gets exactly what the copy checks pin;
// tests/install.test.mjs checks each button's command against the text
// shown beside it.

const COPY_RESET_MS = 1400;
export const INSTALL_COMMANDS = {
  winget: 'winget install --id AmanThanvi.noctty -e',
  'scoop-bucket': 'scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty',
  'scoop-install': 'scoop install noctty/noctty',
  choco: 'choco install noctty',
};

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

function initCopyButtons() {
  const status = document.getElementById('nc-copy-status');

  for (const button of document.querySelectorAll('[data-nc-copy]')) {
    const text = INSTALL_COMMANDS[button.dataset.ncCopy];
    if (!text) continue;

    // "Copy the WinGet command" -> "the WinGet command", for the messages.
    const idleLabel = button.getAttribute('aria-label') || 'Copy command';
    const what = idleLabel.replace(/^Copy\s+/, '');
    let copyTimer = null;

    function setCopyState(state) {
      if (copyTimer !== null) {
        clearTimeout(copyTimer);
        copyTimer = null;
      }
      button.classList.toggle('is-copied', state === 'copied');
      button.classList.toggle('is-failed', state === 'failed');
      const label =
        state === 'copied' ? `Copied ${what}` : state === 'failed' ? `Could not copy ${what}` : idleLabel;
      button.setAttribute('aria-label', label);
      if (status) {
        if (state !== 'idle') status.textContent = label;
        // On reset, clear only this button's own message.
        else if (status.textContent.endsWith(what)) status.textContent = '';
      }
      if (state !== 'idle') {
        copyTimer = setTimeout(() => {
          copyTimer = null;
          setCopyState('idle');
        }, COPY_RESET_MS);
      }
    }

    button.addEventListener('click', () => {
      // Clear first so a repeated copy of the same command is announced again.
      if (status) status.textContent = '';
      writeClipboardText(text)
        .then(() => setCopyState('copied'))
        .catch(() => setCopyState('failed'));
    });
  }
}

if (typeof document !== 'undefined') initCopyButtons();
