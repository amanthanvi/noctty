// Copies the install commands (landing page) and the release verification
// commands (About page). The copied text comes from these constants, not the
// page, so the clipboard gets exactly what the copy checks pin;
// tests/install.test.mjs checks each button's command against the text
// shown beside it.

const COPY_RESET_MS = 1400;
// A failure stays up long enough to read and act on.
const COPY_FAILED_RESET_MS = 6000;
export const INSTALL_COMMANDS = {
  winget: 'winget install --id AmanThanvi.noctty -e',
  'scoop-bucket': 'scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty',
  'scoop-install': 'scoop install noctty/noctty',
  choco: 'choco install noctty',
};

// One line per command, as the About page shows them.
export const VERIFY_COMMANDS = {
  'verify-checksum': [
    'Get-FileHash .\\noctty-<version>-windows-<arch>-setup.exe -Algorithm SHA256',
    'Get-FileHash .\\noctty-<version>-windows-<arch>-portable.zip -Algorithm SHA256',
  ].join('\n'),
  'verify-release': [
    '$version = "<1.3.124-or-later>"',
    'git clone --branch "v$version" --depth 1 https://github.com/amanthanvi/noctty.git',
    'Set-Location .\\noctty',
    '$env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED = "true"',
    'pwsh .\\scripts\\verify-published-release.ps1 -Version $version',
  ].join('\n'),
};

const COMMANDS = { ...INSTALL_COMMANDS, ...VERIFY_COMMANDS };

function writeClipboardTextFallback(text) {
  // Selecting the staging textarea moves focus to it; give focus back to
  // whatever had it (the copy button) once the textarea is gone.
  const returnFocus = document.activeElement;
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
    if (returnFocus && typeof returnFocus.focus === 'function') returnFocus.focus({ preventScroll: true });
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

// How to finish a copy by hand: a keyboard shortcut where there is a fine
// pointer, the selection's own menu on a touch screen.
function finishByHand() {
  const coarse = window.matchMedia?.('(pointer: coarse)').matches;
  return coarse ? 'copy it from the selection menu' : 'press Ctrl+C to copy it';
}

function selectCommand(button) {
  const code = button.closest('.nc-cmd, .nc-proof')?.querySelector('code');
  const selection = window.getSelection?.();
  if (!code || !selection) return;
  selection.selectAllChildren(code);
}

function initCopyButtons() {
  const status = document.getElementById('nc-copy-status');
  // The page has one selection, so only one failed copy can claim it: a new
  // failure clears the previous button's note.
  let clearActiveFailure = null;

  for (const button of document.querySelectorAll('[data-nc-copy]')) {
    const text = COMMANDS[button.dataset.ncCopy];
    if (!text) continue;

    // "Copy the WinGet command" -> "the WinGet command", for the messages.
    const idleLabel = button.getAttribute('aria-label') || 'Copy command';
    const what = idleLabel.replace(/^Copy\s+/, '');
    let copyTimer = null;
    let announced = '';

    const clearFailure = () => setCopyState('idle');

    function setCopyState(state) {
      if (copyTimer !== null) {
        clearTimeout(copyTimer);
        copyTimer = null;
      }
      if (state === 'failed') {
        if (clearActiveFailure && clearActiveFailure !== clearFailure) clearActiveFailure();
        clearActiveFailure = clearFailure;
      } else if (clearActiveFailure === clearFailure) {
        clearActiveFailure = null;
      }
      button.classList.toggle('is-copied', state === 'copied');
      button.classList.toggle('is-failed', state === 'failed');
      // The command makes room under itself for the failure label.
      button.closest('.nc-cmd')?.classList.toggle('has-copy-note', state === 'failed');
      const label =
        state === 'copied'
          ? `Copied ${what}`
          : state === 'failed'
            ? `Could not copy ${what}. It is selected; ${finishByHand()}.`
            : idleLabel;
      button.setAttribute('aria-label', label);
      // The clipboard refused: select the command on the page so a manual
      // Ctrl+C copies it, and say so on the button.
      if (state === 'failed') selectCommand(button);
      if (status) {
        if (state !== 'idle') status.textContent = label;
        // On reset, clear only this button's own message.
        else if (status.textContent === announced) status.textContent = '';
        announced = state !== 'idle' ? label : '';
      }
      if (state !== 'idle') {
        copyTimer = setTimeout(() => {
          copyTimer = null;
          setCopyState('idle');
        }, state === 'failed' ? COPY_FAILED_RESET_MS : COPY_RESET_MS);
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
