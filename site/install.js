// Install command switcher and clipboard copy.

const COPY_RESET_MS = 1400;

const INSTALL_METHODS = {
  scoop: {
    cmd: 'scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty; scoop install winghostty/winghostty',
    copy: 'scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty\r\nscoop install winghostty/winghostty',
  },
  winget: {
    cmd: 'winget install AmanThanvi.winghostty',
    copy: 'winget install AmanThanvi.winghostty',
  },
};

function writeClipboardTextFallback(text) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  textarea.setAttribute('readonly', '');
  textarea.setAttribute('aria-hidden', 'true');
  textarea.tabIndex = -1;
  textarea.className = 'wg-clipboard-stage';
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

const command = document.getElementById('wg-install-command');
const copyButton = document.getElementById('wg-install-copy');
const status = document.getElementById('wg-install-status');
const radios = Array.from(document.querySelectorAll('input[name="install-method"]'));

if (command && copyButton && status && radios.length) {
  let method = radios.find((radio) => radio.checked)?.value || 'winget';
  let copyTimer = null;

  function clearCopyTimer() {
    if (copyTimer === null) return;
    clearTimeout(copyTimer);
    copyTimer = null;
  }

  function setCopyState(state) {
    clearCopyTimer();
    copyButton.classList.toggle('is-copied', state === 'copied');
    copyButton.classList.toggle('is-failed', state === 'failed');
    copyButton.setAttribute(
      'aria-label',
      state === 'copied' ? 'Copied' : state === 'failed' ? 'Copy failed' : 'Copy install command',
    );
    status.textContent = state === 'copied' ? 'Copied' : state === 'failed' ? 'Copy failed' : '';
    if (state !== 'idle') {
      copyTimer = setTimeout(() => {
        copyTimer = null;
        setCopyState('idle');
      }, COPY_RESET_MS);
    }
  }

  function applyMethod(next) {
    method = next in INSTALL_METHODS ? next : 'winget';
    const active = INSTALL_METHODS[method];
    command.textContent = active.cmd;
    command.setAttribute('title', active.cmd);
    setCopyState('idle');
  }

  radios.forEach((radio) => {
    radio.addEventListener('change', () => {
      if (radio.checked) applyMethod(radio.value);
    });
  });

  copyButton.addEventListener('click', () => {
    writeClipboardText(INSTALL_METHODS[method].copy)
      .then(() => setCopyState('copied'))
      .catch(() => setCopyState('failed'));
  });

  applyMethod(method);
}
