const { ipcRenderer } = require('electron');

// Target identification
const urlParams = new URLSearchParams(window.location.search);
const currentTargetId = urlParams.get('target') || 'terminal';
const currentTargetName = urlParams.get('name') || (currentTargetId === 'notes' ? 'Notes' : (currentTargetId === 'textedit' ? 'TextEdit' : 'Terminal'));

document.title = `GC // ${currentTargetName}`;

const isMac = process.platform === 'darwin';
const copyShortcutDesc = isMac ? 'Shift+Cmd+X' : 'Ctrl+Alt+X';
const checkShortcutDesc = isMac ? 'Shift+Cmd+Z' : 'Ctrl+Alt+Z';

// DOM Elements
const hudContainer = document.getElementById('hudContainer');

// Header elements in unified editor
const stageLabel = document.getElementById('stageLabel');
const typingCounter = document.getElementById('typingCounter');
const reviewStageGroup = document.getElementById('reviewStageGroup');
const firstReviewArrow = document.getElementById('firstReviewArrow');
const reviewTag = document.getElementById('reviewTag');
const checkingIndicator = document.getElementById('checkingIndicator');
const lastReviewArrow = document.getElementById('lastReviewArrow');
const correctionBadge = document.getElementById('correctionBadge');

// Set initial stage label to target name (e.g., "Terminal" or "Notes")
if (stageLabel) {
  stageLabel.textContent = currentTargetName;
  stageLabel.title = `Tracking ${currentTargetName} (Press ${copyShortcutDesc} to type directly in GC)`;
}

// Unified Editor Area
const editorTextBox = document.getElementById('editorTextBox');
const typingTextBox = editorTextBox; // alias for backwards compatibility
const correctedTextBox = editorTextBox; // alias for backwards compatibility

const btnCheckHotkey = document.getElementById('btnCheckHotkey');
const btnCheckText = document.getElementById('btnCheckText');
const hotkeyCheckPill = document.getElementById('hotkeyCheckPill');
const btnUndoHotkey = document.getElementById('btnUndoHotkey');
const btnUndoText = document.getElementById('btnUndoText');
const hotkeyUndoPill = document.getElementById('hotkeyUndoPill');
const btnCopyHotkey = document.getElementById('btnCopyHotkey');
const btnCopyText = document.getElementById('btnCopyText');
const btnClear = document.getElementById('btnClear');
const metaLatency = document.getElementById('metaLatency');
const btnModelSelector = document.getElementById('btnModelSelector');
const activeModelLabel = document.getElementById('activeModelLabel');
const modelPopover = document.getElementById('modelPopover');
const modelList = document.getElementById('modelList');
const btnModelPopoverClose = document.getElementById('btnModelPopoverClose');
const dialectPopover = document.getElementById('dialectPopover');
const dialectList = document.getElementById('dialectList');
const btnDialectPopoverClose = document.getElementById('btnDialectPopoverClose');

const defaultPlaceholder = currentTargetId === 'notes'
  ? 'Type directly in GC or in Notes...'
  : (currentTargetId === 'textedit'
      ? 'Type directly in GC or in TextEdit...'
      : (isMac
          ? 'Type directly in GC or in Terminal, Notes, iTerm2...'
          : 'Type directly in GC or in Terminal, CyberTerminal, Notepad...'));
const defaultReviewPlaceholder = isMac
  ? 'Press <strong>Shift + Cmd + Z</strong> when finished typing to review...'
  : 'Press <strong>Ctrl + Alt + Z</strong> when finished typing to review...';

if (editorTextBox) {
  editorTextBox.setAttribute('data-placeholder', defaultPlaceholder);
}

if (isMac) {
  if (hotkeyCheckPill) {
    hotkeyCheckPill.textContent = 'Shift+Cmd+Z';
  }
  const copyPill = document.querySelector('.btn-copy .hotkey-pill');
  if (copyPill) {
    copyPill.textContent = 'Shift+Cmd+X';
  }
  if (hotkeyUndoPill) {
    hotkeyUndoPill.textContent = 'Cmd+Z';
  }
  if (btnCheckHotkey) {
    btnCheckHotkey.title = 'Click to choose English check mode (Shift+Cmd+Z to review)';
  }
  if (btnUndoHotkey) {
    btnUndoHotkey.title = 'Undo corrections and return to input mode (Cmd+Z)';
  }
  if (btnCopyHotkey) {
    btnCopyHotkey.title = 'Copy corrected text and auto-paste (Shift+Cmd+X)';
  }
}

if (btnUndoHotkey) {
  btnUndoHotkey.addEventListener('click', (e) => {
    e.stopPropagation();
    ipcRenderer.send('undo-corrections', { targetId: currentTargetId });
  });
}

let isDirectInputActive = false;
let currentOriginalText = '';
let currentCorrectedText = '';
let currentIssues = [];
let savedReviewIssues = [];
let savedReviewCorrectedText = '';
let isCorrectionsUndone = false;
let isReviewMode = false;
let audioCtx = null;

// Lightweight Web Audio feedback
function playTone(freq, type = 'sine', duration = 0.12, gainVal = 0.08) {
  try {
    if (!audioCtx) {
      audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    }
    if (audioCtx.state === 'suspended') {
      audioCtx.resume();
    }
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, audioCtx.currentTime);
    gain.gain.setValueAtTime(gainVal, audioCtx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.0001, audioCtx.currentTime + duration);
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    osc.start();
    osc.stop(audioCtx.currentTime + duration);
  } catch (e) {}
}

function playPopSound() {
  playTone(560, 'sine', 0.08, 0.04);
}

function playReviewDoneSound() {
  playTone(500, 'sine', 0.08, 0.05);
  setTimeout(() => playTone(750, 'sine', 0.12, 0.05), 80);
}

function playSuccessCopySound() {
  playTone(620, 'sine', 0.07, 0.06);
  setTimeout(() => playTone(880, 'sine', 0.14, 0.06), 70);
}

// -------------------------------------------------------------
// UI Actions & Window Control
// -------------------------------------------------------------
// Top right close button
const btnClose = document.getElementById('btnClose');
if (btnClose) {
  btnClose.addEventListener('click', (e) => {
    e.stopPropagation();
    ipcRenderer.send('close-hovering-window', { targetId: currentTargetId });
  });
}

// Keyboard shortcuts inside window
window.addEventListener('keydown', (e) => {
  // Check Hotkey inside window: Win: Ctrl+Alt+Z / Mac: Shift+Cmd+Z
  const isCheckHotkey = isMac
    ? (e.metaKey && e.shiftKey && (e.key === 'z' || e.key === 'Z'))
    : (e.ctrlKey && e.altKey && (e.key === 'z' || e.key === 'Z'));

  if (isCheckHotkey) {
    e.preventDefault();
    e.stopPropagation();
    const currentText = (editorTextBox ? editorTextBox.innerText : currentOriginalText || '').trim();
    if (currentText) {
      setCheckingModeUI();
      ipcRenderer.send('trigger-check-manual', { targetId: currentTargetId, text: currentText });
    }
    return;
  }

  // Undo Hotkey inside window: Win: Ctrl+Z / Mac: Cmd+Z (revert to original inputs during review)
  const isUndoHotkey = isMac
    ? (e.metaKey && !e.shiftKey && !e.altKey && (e.key === 'z' || e.key === 'Z'))
    : (e.ctrlKey && !e.shiftKey && !e.altKey && (e.key === 'z' || e.key === 'Z'));

  if (isUndoHotkey && isReviewMode) {
    e.preventDefault();
    e.stopPropagation();
    ipcRenderer.send('undo-corrections', { targetId: currentTargetId });
    return;
  }

  // Copy Hotkey inside window: Win: Ctrl+Alt+X / Mac: Shift+Cmd+X
  const isCopyHotkey = isMac
    ? (e.metaKey && e.shiftKey && (e.key === 'x' || e.key === 'X'))
    : (e.ctrlKey && e.altKey && (e.key === 'x' || e.key === 'X'));

  if (isCopyHotkey) {
    e.preventDefault();
    e.stopPropagation();
    if (isReviewMode) {
      const textToCopy = currentCorrectedText || currentOriginalText;
      if (textToCopy) {
        ipcRenderer.send('copy-corrected-text', { targetId: currentTargetId, text: textToCopy });
      }
    } else {
      focusDirectInput();
    }
    return;
  }

  // Ctrl+Enter or Cmd+Enter to trigger review
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
    e.preventDefault();
    e.stopPropagation();
    const currentText = (editorTextBox ? editorTextBox.innerText : currentOriginalText || '').trim();
    if (currentText) {
      setCheckingModeUI();
      ipcRenderer.send('trigger-check-manual', { targetId: currentTargetId, text: currentText });
    }
    return;
  }

  if (e.key === 'Escape') {
    ipcRenderer.send('close-hovering-window', { targetId: currentTargetId });
  } else if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
    if (document.activeElement === editorTextBox && !isReviewMode) {
      // User is typing inside GC Editor: allow normal newline
      return;
    }
    if (currentTargetId !== 'notes' && currentTargetId !== 'textedit') {
      ipcRenderer.send('close-hovering-window', { targetId: currentTargetId });
    }
  }
});

// -------------------------------------------------------------
// UI Actions
// -------------------------------------------------------------
btnClear.addEventListener('click', (e) => {
  e.stopPropagation();
  ipcRenderer.send('clear-buffer-manual', { targetId: currentTargetId });
  clearDisplay();
  focusDirectInput();
});

// Click stage label to toggle between GC Editor and External Terminal input
if (stageLabel) {
  stageLabel.addEventListener('click', (e) => {
    e.stopPropagation();
    if (isReviewMode) {
      currentOriginalText = currentCorrectedText || currentOriginalText;
      if (editorTextBox) {
        editorTextBox.textContent = currentOriginalText;
      }
      focusDirectInput();
    } else {
      if (isDirectInputActive) {
        isDirectInputActive = false;
        setInputModeUI(currentTargetName);
      } else {
        focusDirectInput();
      }
    }
  });
}

// Trigger review via hotkey pill or dialect button
if (hotkeyCheckPill) {
  hotkeyCheckPill.addEventListener('click', (e) => {
    e.stopPropagation();
    hideDialectPopover();
    const currentText = (editorTextBox ? editorTextBox.innerText : currentOriginalText || '').trim();
    if (currentText) {
      setCheckingModeUI();
      ipcRenderer.send('trigger-check-manual', { targetId: currentTargetId, text: currentText });
    }
  });
}

if (btnCheckHotkey) {
  btnCheckHotkey.addEventListener('click', (e) => {
    e.stopPropagation();
    if (e.target === hotkeyCheckPill || (hotkeyCheckPill && hotkeyCheckPill.contains(e.target))) {
      return;
    }
    if (!dialectPopover) return;
    const isVisible = dialectPopover.style.display === 'flex';
    if (isVisible) {
      hideDialectPopover();
    } else {
      showDialectPopover();
    }
  });
}

if (correctionBadge) {
  correctionBadge.addEventListener('click', (e) => {
    e.stopPropagation();
    const currentText = (editorTextBox ? editorTextBox.innerText : currentOriginalText || '').trim();
    if (currentText) {
      setCheckingModeUI();
      ipcRenderer.send('trigger-check-manual', { targetId: currentTargetId, text: currentText });
    }
  });
}

// Copy corrected text (mouse equivalent of Ctrl + Alt + X)
btnCopyHotkey.addEventListener('click', (e) => {
  e.stopPropagation();
  const textToCopy = currentCorrectedText || currentOriginalText;
  if (textToCopy) {
    ipcRenderer.send('copy-corrected-text', { targetId: currentTargetId, text: textToCopy });
  }
});

function setInputModeUI(sourceName = null) {
  isReviewMode = false;
  ipcRenderer.send('set-input-mode', { targetId: currentTargetId });
  if (stageLabel) {
    if (sourceName === 'GC Editor' || isDirectInputActive) {
      isDirectInputActive = true;
      stageLabel.textContent = 'GC Editor';
      stageLabel.title = `Direct GC Editor input (Click or press ${copyShortcutDesc} to toggle)`;
      stageLabel.classList.add('direct-gc');
    } else {
      isDirectInputActive = false;
      stageLabel.textContent = sourceName || currentTargetName;
      stageLabel.title = `Tracking ${sourceName || currentTargetName} (Press ${copyShortcutDesc} to type directly in GC)`;
      stageLabel.classList.remove('direct-gc');
    }
    stageLabel.classList.remove('dimmed');
    stageLabel.classList.add('active');
  }
  if (editorTextBox) {
    editorTextBox.setAttribute('contenteditable', 'plaintext-only');
    editorTextBox.classList.remove('review-expanded');
    const text = (editorTextBox.innerText || '').trim();
    if (!text) {
      editorTextBox.setAttribute('data-empty', 'true');
    } else {
      editorTextBox.setAttribute('data-empty', 'false');
    }
  }
  if (reviewStageGroup) {
    reviewStageGroup.style.display = 'none';
  }
  if (checkingIndicator) {
    checkingIndicator.style.display = 'none';
  }
  if (lastReviewArrow) {
    lastReviewArrow.style.display = 'none';
  }
  if (correctionBadge) {
    correctionBadge.style.display = 'none';
  }
  if (reviewTag) {
    reviewTag.textContent = 'Checking';
    reviewTag.className = 'stage-label review-label';
  }
  if (btnUndoHotkey) {
    btnUndoHotkey.style.display = 'none';
    btnUndoHotkey.classList.remove('undone');
    if (btnUndoText) btnUndoText.textContent = 'Undo';
  }
  isCorrectionsUndone = false;
}

function focusDirectInput() {
  isDirectInputActive = true;
  setInputModeUI('GC Editor');
  if (editorTextBox) {
    editorTextBox.setAttribute('contenteditable', 'plaintext-only');
    editorTextBox.classList.remove('review-expanded');
    const text = (editorTextBox.innerText || '').trim();
    if (!text) {
      editorTextBox.textContent = '';
      editorTextBox.setAttribute('data-empty', 'true');
    } else {
      editorTextBox.setAttribute('data-empty', 'false');
    }
    editorTextBox.focus();
    try {
      const range = document.createRange();
      const sel = window.getSelection();
      range.selectNodeContents(editorTextBox);
      range.collapse(false);
      sel.removeAllRanges();
      sel.addRange(range);
    } catch (e) {}
  }
}

// Direct typing & editing inside editorTextBox
if (editorTextBox) {
  editorTextBox.addEventListener('focus', () => {
    if (!isReviewMode) {
      isDirectInputActive = true;
      setInputModeUI('GC Editor');
    }
  });

  editorTextBox.addEventListener('input', () => {
    if (isReviewMode) return;
    isDirectInputActive = true;
    setInputModeUI('GC Editor');

    const text = (editorTextBox.innerText || '').replace(/\r\n/g, '\n');
    currentOriginalText = text;

    const trimmed = text.trim();
    if (!trimmed) {
      editorTextBox.setAttribute('data-empty', 'true');
      if (typingCounter) {
        typingCounter.textContent = '[0 words (0 ch)]';
      }
    } else {
      editorTextBox.setAttribute('data-empty', 'false');
      const words = trimmed.split(/\s+/).length;
      const length = text.length;
      if (typingCounter) {
        typingCounter.textContent = `[${words} word${words === 1 ? '' : 's'} (${length} ch)]`;
      }
    }

    ipcRenderer.send('manual-typing-input', {
      targetId: currentTargetId,
      text
    });
  });
}

function setCheckingModeUI() {
  isReviewMode = true;
  if (stageLabel) {
    stageLabel.textContent = isDirectInputActive ? 'GC Editor' : currentTargetName;
    stageLabel.classList.remove('active');
    stageLabel.classList.add('dimmed');
  }
  if (editorTextBox) {
    editorTextBox.setAttribute('contenteditable', 'false');
    editorTextBox.setAttribute('data-empty', 'false');
    editorTextBox.classList.add('review-expanded');
  }
  if (reviewStageGroup) {
    reviewStageGroup.style.display = 'inline-flex';
  }
  if (firstReviewArrow) {
    firstReviewArrow.style.display = 'inline-flex';
  }
  if (reviewTag) {
    reviewTag.textContent = 'Checking';
    reviewTag.className = 'stage-label review-label checking';
  }
  if (checkingIndicator) {
    checkingIndicator.style.display = 'inline-flex';
  }
  if (lastReviewArrow) {
    lastReviewArrow.style.display = 'none';
  }
  if (correctionBadge) {
    correctionBadge.style.display = 'none';
  }
  if (btnUndoHotkey) {
    btnUndoHotkey.style.display = 'none';
  }
}

function setReviewedModeUI(hasCorrections) {
  isReviewMode = true;
  if (stageLabel) {
    stageLabel.textContent = isDirectInputActive ? 'GC Editor' : currentTargetName;
    stageLabel.classList.remove('active');
    stageLabel.classList.add('dimmed');
  }
  if (editorTextBox) {
    editorTextBox.setAttribute('contenteditable', 'false');
    editorTextBox.setAttribute('data-empty', 'false');
  }
  if (reviewStageGroup) {
    reviewStageGroup.style.display = 'inline-flex';
  }
  if (firstReviewArrow) {
    firstReviewArrow.style.display = 'inline-flex';
  }
  if (checkingIndicator) {
    checkingIndicator.style.display = 'none';
  }
  if (reviewTag) {
    reviewTag.textContent = 'Reviewed';
    reviewTag.className = 'stage-label review-label reviewed';
  }
  if (lastReviewArrow) {
    lastReviewArrow.style.display = 'inline-flex';
    if (hasCorrections) {
      lastReviewArrow.className = 'header-arrow result-transition-arrow arrow-blue';
    } else {
      lastReviewArrow.className = 'header-arrow result-transition-arrow arrow-green';
    }
  }
  if (correctionBadge) {
    correctionBadge.style.display = 'inline-block';
  }
  if (btnUndoHotkey) {
    btnUndoHotkey.style.display = 'inline-flex';
    btnUndoHotkey.classList.remove('undone');
    if (btnUndoText) btnUndoText.textContent = 'Undo';
  }
}

function clearDisplay() {
  currentOriginalText = '';
  currentCorrectedText = '';
  currentIssues = [];
  savedReviewIssues = [];
  savedReviewCorrectedText = '';
  isCorrectionsUndone = false;
  if (btnUndoHotkey) {
    btnUndoHotkey.style.display = 'none';
    btnUndoHotkey.classList.remove('undone');
    if (btnUndoText) btnUndoText.textContent = 'Undo';
  }
  setInputModeUI(isDirectInputActive ? 'GC Editor' : currentTargetName);
  if (typingCounter) {
    typingCounter.textContent = '[0 words (0 ch)]';
  }
  if (correctionBadge) {
    correctionBadge.textContent = '[✓]';
    correctionBadge.className = 'correction-badge-btn';
    correctionBadge.style.display = 'none';
  }
  if (editorTextBox) {
    editorTextBox.classList.remove('review-expanded');
    editorTextBox.textContent = '';
    editorTextBox.setAttribute('data-empty', 'true');
    editorTextBox.setAttribute('contenteditable', 'plaintext-only');
  }
  if (metaLatency) {
    metaLatency.textContent = '-- ms';
  }
}

function escapeHtml(str) {
  if (!str) return '';
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function recalculateCorrectedTextFromDOM() {
  if (!editorTextBox) return;
  let text = '';
  for (const node of editorTextBox.childNodes) {
    if (node.nodeType === Node.TEXT_NODE) {
      text += node.textContent;
    } else if (node.classList && node.classList.contains('inline-correction-token')) {
      const origSpan = node.querySelector('.inline-original-word');
      const replVal = node.getAttribute('data-repl');
      if (node.classList.contains('accepted')) {
        text += (replVal !== 'delete' ? replVal : '');
      } else {
        text += origSpan ? origSpan.textContent : '';
      }
    } else {
      text += node.textContent;
    }
  }
  currentCorrectedText = text;
  ipcRenderer.send('update-corrected-text', { targetId: currentTargetId, text });
}

// -------------------------------------------------------------
// Grammarly-Style Inline Review Renderer
// -------------------------------------------------------------
function renderInlineReview(originalText, correctedText, issues) {
  if (!editorTextBox) return;

  if (!originalText || !originalText.trim()) {
    editorTextBox.innerHTML = `<span class="placeholder-text">${defaultReviewPlaceholder}</span>`;
    return;
  }

  if (!issues || issues.length === 0) {
    editorTextBox.textContent = correctedText || originalText;
    return;
  }

  const matches = [];
  const lowerOriginal = originalText.toLowerCase();

  for (let i = 0; i < issues.length; i++) {
    const issue = issues[i];
    const orig = (issue.original || '').trim();
    const repl = (issue.replacement !== undefined ? issue.replacement : '').trim();
    if (!orig || orig === repl) continue;

    const lowerOrig = orig.toLowerCase();
    let searchStart = 0;
    while (searchStart < lowerOriginal.length) {
      const idx = lowerOriginal.indexOf(lowerOrig, searchStart);
      if (idx === -1) break;

      const isWord = /^[a-zA-Z0-9]+$/.test(orig);
      let isValidBoundary = true;
      if (isWord) {
        const charBefore = idx > 0 ? originalText[idx - 1] : ' ';
        const charAfter = (idx + orig.length < originalText.length) ? originalText[idx + orig.length] : ' ';
        if (/[a-zA-Z0-9]/.test(charBefore) || /[a-zA-Z0-9]/.test(charAfter)) {
          isValidBoundary = false;
        }
      }

      if (isValidBoundary) {
        matches.push({
          start: idx,
          end: idx + orig.length,
          original: originalText.substring(idx, idx + orig.length),
          replacement: repl,
          type: (issue.type || 'spelling').toLowerCase(),
          explanation: issue.explanation || `${issue.type || 'Correction'}: ${orig} → ${repl}`,
          issueIndex: i
        });
        searchStart = idx + orig.length;
      } else {
        searchStart = idx + 1;
      }
    }
  }

  // Fallback: If strict boundary check yielded no matches, search loosely
  if (matches.length === 0) {
    for (let i = 0; i < issues.length; i++) {
      const issue = issues[i];
      const orig = (issue.original || '').trim();
      const repl = (issue.replacement !== undefined ? issue.replacement : '').trim();
      if (!orig) continue;

      const lowerOrig = orig.toLowerCase();
      let searchStart = 0;
      while (searchStart < lowerOriginal.length) {
        const idx = lowerOriginal.indexOf(lowerOrig, searchStart);
        if (idx === -1) break;
        matches.push({
          start: idx,
          end: idx + orig.length,
          original: originalText.substring(idx, idx + orig.length),
          replacement: repl,
          type: (issue.type || 'spelling').toLowerCase(),
          explanation: issue.explanation || `${issue.type || 'Correction'}: ${orig} → ${repl}`,
          issueIndex: i
        });
        searchStart = idx + orig.length;
      }
    }
  }

  // Sort matches by start position ascending (prefer longer matches on tie)
  matches.sort((a, b) => a.start - b.start || (b.end - b.start) - (a.end - a.start));

  // Filter overlapping matches
  const nonOverlapping = [];
  let lastEnd = 0;
  for (const m of matches) {
    if (m.start >= lastEnd) {
      nonOverlapping.push(m);
      lastEnd = m.end;
    }
  }

  if (nonOverlapping.length === 0) {
    editorTextBox.textContent = correctedText || originalText;
    return;
  }

  let html = '';
  let cursor = 0;
  for (let idx = 0; idx < nonOverlapping.length; idx++) {
    const m = nonOverlapping[idx];
    if (m.start > cursor) {
      html += escapeHtml(originalText.substring(cursor, m.start));
    }

    const typeClass = m.type === 'grammar' ? 'grammar' : (m.type === 'vocabulary' ? 'vocabulary' : 'spelling');
    const typeLabel = m.type === 'grammar' ? 'Grammar' : (m.type === 'vocabulary' ? 'Vocabulary' : 'Spelling (UK)');
    const tooltip = escapeHtml(`${typeLabel}: ${m.explanation}`);
    const displayRepl = m.replacement ? escapeHtml(m.replacement) : 'delete';
    const displayOrig = escapeHtml(m.original);

    const lenDiff = m.replacement.length - m.original.length;
    const extraMargin = lenDiff > 0 ? Math.min(16, Math.max(4, Math.round(lenDiff * 3.5))) : 4;
    const popDelay = Math.min(idx * 35, 350);

    html += `<span class="inline-correction-token ${typeClass}" style="margin: 0 ${extraMargin}px;" data-orig="${displayOrig}" data-repl="${displayRepl}" title="${tooltip}">` +
      `<span class="inline-correction-pill" style="animation-delay: ${popDelay}ms;">${displayRepl}</span>` +
      `<span class="inline-original-word">${displayOrig}</span>` +
    `</span>`;

    cursor = m.end;
  }

  if (cursor < originalText.length) {
    html += escapeHtml(originalText.substring(cursor));
  }

  editorTextBox.innerHTML = html;

  // Clicking an inline suggestion accepts that correction
  const tokens = editorTextBox.querySelectorAll('.inline-correction-token');
  tokens.forEach((token) => {
    token.addEventListener('click', (e) => {
      e.stopPropagation();
      if (token.classList.contains('accepted')) return;
      token.classList.add('accepted');
      const origSpan = token.querySelector('.inline-original-word');
      const replVal = token.getAttribute('data-repl');
      if (origSpan && replVal && replVal !== 'delete') {
        origSpan.textContent = replVal;
      }
      playPopSound();
      recalculateCorrectedTextFromDOM();
    });
  });
}

// -------------------------------------------------------------
// IPC Handlers
// -------------------------------------------------------------
ipcRenderer.on('focus-input-mode', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;
  hudContainer.classList.add('visible');
  focusDirectInput();
  playPopSound();
});

ipcRenderer.on('window-popped', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;
  hudContainer.classList.add('visible');
  playPopSound();
});

ipcRenderer.on('window-closed', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;
  hudContainer.classList.remove('visible');
  clearDisplay();
});

ipcRenderer.on('typing-update', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;
  const { text, length, words } = data;

  // If user is actively typing directly inside GC editor, ignore external stream
  if (document.activeElement === editorTextBox && isDirectInputActive) {
    return;
  }

  currentOriginalText = text || '';

  if (!text || text.length === 0) {
    clearDisplay();
    return;
  }

  // If user resumes typing while in review mode, smoothly collapse back to input mode
  if (isReviewMode) {
    setInputModeUI(currentTargetName);
    currentCorrectedText = '';
    currentIssues = [];
    if (editorTextBox) editorTextBox.classList.remove('review-expanded');
  } else {
    setInputModeUI(currentTargetName);
  }

  if (typingCounter) {
    typingCounter.textContent = `[${words} word${words === 1 ? '' : 's'} (${length} ch)]`;
  }

  // Display raw real-time typed text in compact mode
  if (editorTextBox) {
    editorTextBox.textContent = text;
    editorTextBox.setAttribute('data-empty', 'false');
    editorTextBox.scrollTop = editorTextBox.scrollHeight;
  }
});

ipcRenderer.on('correction-checking', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;
  setCheckingModeUI();

  // Smoothly expand line spacing to fit inline corrections
  if (editorTextBox) {
    editorTextBox.classList.add('review-expanded');
  }
});

ipcRenderer.on('correction-result', (event, result) => {
  if (result && result.targetId && result.targetId !== currentTargetId) return;
  playReviewDoneSound();

  if (editorTextBox) editorTextBox.classList.add('review-expanded');

  const dialectKey = result.dialect || currentActiveDialect || 'en-GB';
  const adj = DIALECT_ADJECTIVES[dialectKey] || 'English';

  const validIssues = (result.issues || []).filter(issue => {
    if (!issue || typeof issue !== 'object') return false;
    const orig = String(issue.original || '').trim();
    const repl = String(issue.replacement !== undefined ? issue.replacement : '').trim();
    return orig.length > 0 && orig !== repl;
  });

  let cleanCorrected = (result && typeof result.corrected === 'string' && result.corrected.trim())
    ? result.corrected.trim()
    : currentOriginalText;

  // Safety filter: ensure corrected text is clean human-readable text, never raw JSON or metadata
  if (cleanCorrected.startsWith('{"') ||
      cleanCorrected.startsWith('`') ||
      cleanCorrected.includes('"issues":') ||
      cleanCorrected.includes('"replacement":') ||
      cleanCorrected.includes('"model":')) {
    cleanCorrected = currentOriginalText;
  }

  if (result.status === 'clean' || validIssues.length === 0) {
    currentCorrectedText = cleanCorrected;
    currentIssues = [];
    if (editorTextBox) editorTextBox.textContent = currentCorrectedText;
    setReviewedModeUI(false); // No corrections: green arrow
    if (correctionBadge) {
      if (dialectKey === 'en-CN') {
        correctionBadge.textContent = '[✓ Authentic Chinglish]';
      } else {
        correctionBadge.textContent = `[✓ Perfect ${adj} English]`;
      }
      correctionBadge.className = 'correction-badge-btn perfect';
    }
  } else if (result.status === 'corrected') {
    currentCorrectedText = cleanCorrected;
    currentIssues = validIssues;

    const count = currentIssues.length;
    setReviewedModeUI(true); // Has corrections: blue-ish arrow
    if (correctionBadge) {
      if (dialectKey === 'en-CN') {
        correctionBadge.textContent = `[✓ ${count} Chinglish Expression${count === 1 ? '' : 's'}]`;
      } else {
        correctionBadge.textContent = `[✓ ${count} ${adj} Correction${count === 1 ? '' : 's'}]`;
      }
      correctionBadge.className = 'correction-badge-btn corrected';
    }

    renderInlineReview(currentOriginalText, currentCorrectedText, currentIssues);
  } else if (result.status === 'error') {
    currentCorrectedText = cleanCorrected;
    if (editorTextBox) editorTextBox.textContent = currentCorrectedText;
    setReviewedModeUI(false);
    if (lastReviewArrow) {
      lastReviewArrow.className = 'header-arrow result-transition-arrow arrow-error';
    }
    if (correctionBadge) {
      correctionBadge.textContent = '[Ollama Error]';
      correctionBadge.className = 'correction-badge-btn error';
    }
  }

  if (result.durationMs && metaLatency) {
    metaLatency.textContent = `${result.durationMs} ms`;
    metaLatency.title = `Inference Latency: ${result.durationMs} ms`;
  }

  savedReviewIssues = validIssues;
  savedReviewCorrectedText = cleanCorrected;
  isCorrectionsUndone = false;
});

ipcRenderer.on('undo-to-input-mode', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;

  // Restore original uncorrected text and clear review state
  currentOriginalText = data.originalText !== undefined ? data.originalText : currentOriginalText;
  currentCorrectedText = currentOriginalText;
  currentIssues = [];
  savedReviewIssues = [];
  savedReviewCorrectedText = '';
  isCorrectionsUndone = false;

  // Return GC to Input Mode (removes Reviewed and the number of corrections)
  setInputModeUI(isDirectInputActive ? 'GC Editor' : currentTargetName);

  if (editorTextBox) {
    editorTextBox.textContent = currentOriginalText;
    const trimmed = (currentOriginalText || '').trim();
    if (!trimmed) {
      editorTextBox.setAttribute('data-empty', 'true');
    } else {
      editorTextBox.setAttribute('data-empty', 'false');
    }

    if (isDirectInputActive) {
      editorTextBox.focus();
      try {
        const range = document.createRange();
        const sel = window.getSelection();
        range.selectNodeContents(editorTextBox);
        range.collapse(false);
        sel.removeAllRanges();
        sel.addRange(range);
      } catch (e) {}
    }
  }

  if (typingCounter) {
    const trimmed = (currentOriginalText || '').trim();
    if (!trimmed) {
      typingCounter.textContent = '[0 words (0 ch)]';
    } else {
      const words = trimmed.split(/\s+/).length;
      const length = currentOriginalText.length;
      typingCounter.textContent = `[${words} word${words === 1 ? '' : 's'} (${length} ch)]`;
    }
  }

  playPopSound();
});

// Backwards-compatible alias for any legacy callers
ipcRenderer.on('undo-corrections-toggle', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;
  ipcRenderer.emit('undo-to-input-mode', event, data);
});

ipcRenderer.on('copied-feedback', (event, data) => {
  if (data && data.targetId && data.targetId !== currentTargetId) return;
  btnCopyHotkey.classList.add('copied');
  btnCopyText.textContent = '✓ Copied!';
  playSuccessCopySound();

  setTimeout(() => {
    btnCopyHotkey.classList.remove('copied');
    btnCopyText.textContent = 'Copy';
  }, 1400);
});

ipcRenderer.on('gc-running-state', (event, { isGCRunning, isHoveringWindowPopped }) => {
  // Running state can be reflected in model/latency or HUD border if needed
});

let currentActiveModel = 'gemma4:e4b';
let currentActiveDialect = 'en-GB';

const DIALECT_LABELS = {
  'en-GB': 'en-GB',
  'en-US': 'en-US',
  'en-AU': 'en-AU',
  'en-CN': 'en-CN'
};

const DIALECT_ADJECTIVES = {
  'en-GB': 'UK',
  'en-US': 'US',
  'en-AU': 'AU',
  'en-CN': 'Chinglish'
};

function updateDialectDisplay(dialect) {
  if (!dialect) return;
  currentActiveDialect = dialect;
  if (btnCheckText) {
    btnCheckText.textContent = DIALECT_LABELS[dialect] || dialect;
  }
  if (btnCheckHotkey) {
    btnCheckHotkey.title = `Current Mode: ${DIALECT_LABELS[dialect] || dialect} (Click to change mode, press Ctrl+Alt+Z to review)`;
  }
  if (dialectList) {
    const items = dialectList.querySelectorAll('.model-item');
    items.forEach(item => {
      const d = item.getAttribute('data-dialect');
      if (d === dialect) {
        item.classList.add('active');
        if (!item.querySelector('.model-item-check')) {
          const chk = document.createElement('span');
          chk.className = 'model-item-check';
          chk.textContent = '✓';
          item.appendChild(chk);
        }
      } else {
        item.classList.remove('active');
        const chk = item.querySelector('.model-item-check');
        if (chk) chk.remove();
      }
    });
  }
}

function hideDialectPopover() {
  if (dialectPopover) {
    dialectPopover.style.display = 'none';
  }
  if (btnCheckHotkey) {
    btnCheckHotkey.classList.remove('popover-open');
  }
}

function showDialectPopover() {
  if (!dialectPopover) return;
  hideModelPopover();
  if (btnCheckHotkey && hudContainer) {
    const rect = btnCheckHotkey.getBoundingClientRect();
    const hudRect = hudContainer.getBoundingClientRect();
    const offsetLeft = Math.max(14, Math.round(rect.left - hudRect.left));
    dialectPopover.style.left = `${offsetLeft}px`;
    dialectPopover.style.right = 'auto';
  }
  dialectPopover.style.display = 'flex';
  if (btnCheckHotkey) {
    btnCheckHotkey.classList.add('popover-open');
  }
}

function selectDialect(dialect) {
  playPopSound();
  updateDialectDisplay(dialect);
  ipcRenderer.send('switch-dialect', dialect);
  hideDialectPopover();
}

if (dialectList) {
  const items = dialectList.querySelectorAll('.model-item');
  items.forEach(item => {
    item.addEventListener('click', (e) => {
      e.stopPropagation();
      const d = item.getAttribute('data-dialect');
      if (d) selectDialect(d);
    });
  });
}

if (btnDialectPopoverClose) {
  btnDialectPopoverClose.addEventListener('click', (e) => {
    e.stopPropagation();
    hideDialectPopover();
  });
}

if (dialectPopover) {
  dialectPopover.addEventListener('click', (e) => {
    e.stopPropagation();
  });
}

function updateModelDisplay(modelName) {
  if (!modelName) return;
  currentActiveModel = modelName;
  if (activeModelLabel) {
    activeModelLabel.textContent = modelName;
  }
  if (btnModelSelector) {
    btnModelSelector.title = `Active Model: ${modelName} (Click to switch)`;
  }
}

function hideModelPopover() {
  if (modelPopover) {
    modelPopover.style.display = 'none';
  }
  if (btnModelSelector) {
    btnModelSelector.classList.remove('popover-open');
  }
}

function showModelPopover() {
  if (!modelPopover) return;
  hideDialectPopover();
  if (btnModelSelector && hudContainer) {
    const rect = btnModelSelector.getBoundingClientRect();
    const hudRect = hudContainer.getBoundingClientRect();
    const offsetLeft = Math.max(14, Math.round(rect.left - hudRect.left));
    modelPopover.style.left = `${offsetLeft}px`;
    modelPopover.style.right = 'auto';
  }
  modelPopover.style.display = 'flex';
  if (btnModelSelector) {
    btnModelSelector.classList.add('popover-open');
  }
  if (modelList && (!modelList.children || modelList.children.length === 0)) {
    modelList.innerHTML = '<div class="model-item" style="opacity: 0.6; cursor: default;">Loading local models...</div>';
  }
  ipcRenderer.send('get-available-models');
}

if (btnModelSelector) {
  btnModelSelector.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!modelPopover) return;
    const isVisible = modelPopover.style.display === 'flex';
    if (isVisible) {
      hideModelPopover();
    } else {
      showModelPopover();
    }
  });
}

if (btnModelPopoverClose) {
  btnModelPopoverClose.addEventListener('click', (e) => {
    e.stopPropagation();
    hideModelPopover();
  });
}

if (modelPopover) {
  modelPopover.addEventListener('click', (e) => {
    e.stopPropagation();
  });
}

window.addEventListener('click', (e) => {
  if (modelPopover && modelPopover.style.display === 'flex') {
    if (!modelPopover.contains(e.target) && !btnModelSelector.contains(e.target)) {
      hideModelPopover();
    }
  }
  if (dialectPopover && dialectPopover.style.display === 'flex') {
    if (!dialectPopover.contains(e.target) && !btnCheckHotkey.contains(e.target)) {
      hideDialectPopover();
    }
  }
});

function selectModel(modelName) {
  playPopSound();
  updateModelDisplay(modelName);
  ipcRenderer.send('switch-model', modelName);
  hideModelPopover();
}

ipcRenderer.on('available-models-result', (event, { models, activeModel }) => {
  if (activeModel) {
    updateModelDisplay(activeModel);
  }
  if (!modelList) return;
  modelList.innerHTML = '';
  if (!models || models.length === 0) {
    const emptyEl = document.createElement('div');
    emptyEl.className = 'model-item';
    emptyEl.style.opacity = '0.6';
    emptyEl.style.cursor = 'default';
    emptyEl.textContent = 'No local models found';
    modelList.appendChild(emptyEl);
    return;
  }

  const current = activeModel || currentActiveModel;

  models.forEach((modelName) => {
    const item = document.createElement('button');
    const isActive = modelName === current;
    item.className = 'model-item' + (isActive ? ' active' : '');
    item.type = 'button';

    const nameSpan = document.createElement('span');
    nameSpan.className = 'model-item-name';
    nameSpan.textContent = modelName;
    item.appendChild(nameSpan);

    if (isActive) {
      const checkSpan = document.createElement('span');
      checkSpan.className = 'model-item-check';
      checkSpan.textContent = '✓';
      item.appendChild(checkSpan);
    }

    item.addEventListener('click', (e) => {
      e.stopPropagation();
      selectModel(modelName);
    });

    modelList.appendChild(item);
  });
});

ipcRenderer.on('model-changed', (event, modelName) => {
  updateModelDisplay(modelName);
});

ipcRenderer.on('dialect-changed', (event, dialect) => {
  updateDialectDisplay(dialect);
});

// Request initial state
ipcRenderer.send('get-app-state', { targetId: currentTargetId });
ipcRenderer.on('app-state', (event, state) => {
  if (state && state.targetId && state.targetId !== currentTargetId) return;
  if (state.activeModel) {
    updateModelDisplay(state.activeModel);
  }
  if (state.activeDialect) {
    updateDialectDisplay(state.activeDialect);
  }
});

// Direct paste support on the HUD window
window.addEventListener('paste', (e) => {
  if (e.target === editorTextBox || (editorTextBox && editorTextBox.contains(e.target))) {
    // Native contenteditable handles paste at caret position
    return;
  }
  const pasteData = (e.clipboardData || window.clipboardData).getData('text');
  if (pasteData && pasteData.trim()) {
    ipcRenderer.send('paste-manual', { targetId: currentTargetId, text: pasteData });
  }
});

