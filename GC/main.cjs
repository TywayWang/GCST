const { app, BrowserWindow, globalShortcut, ipcMain, Tray, Menu, screen, clipboard, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const http = require('http');
const { KeyMonitorManager } = require('./src/keyMonitorManager.cjs');
const { OllamaClient } = require('./src/ollamaClient.cjs');

// Prevent multiple instances
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
  process.exit(0);
}

const WINDOW_WIDTH = 584;
const WINDOW_HEIGHT = 544;
const isMac = process.platform === 'darwin';

class TargetInstance {
  constructor(targetId, targetName) {
    this.targetId = targetId;
    this.targetName = targetName;
    this.linkedAppName = targetName;
    this.window = null;
    this.isHoveringWindowPopped = false;
    this.isReviewMode = false;
    this.isCorrectionsUndone = false;
    this.savedCorrectedText = '';
    this.currentTypedText = '';
    this.currentCorrectedText = '';
    this.currentIssues = [];
    this.currentAnalysisId = 0;
  }
}

// Target instances map: targetId -> TargetInstance
const targetInstances = new Map();
let activeTargetId = 'terminal';

let tray = null;
let keyMonitor = null;
let ollamaClient = null;
let isGCRunning = false; // Positive when active, negative when stopped
let isAlwaysOnTopEnabled = false; // Defaults to false so GC never blocks other apps/software
let configPath = '';

function loadConfig() {
  try {
    if (fs.existsSync(configPath)) {
      return JSON.parse(fs.readFileSync(configPath, 'utf8'));
    }
  } catch (e) {}
  return { x: null, y: null, positions: {}, activeModel: 'gemma4:e4b', activeDialect: 'en-GB', alwaysOnTop: false };
}

function saveConfig(cfg) {
  try {
    const existing = loadConfig();
    const merged = { ...existing, ...cfg };
    fs.writeFileSync(configPath, JSON.stringify(merged, null, 2), 'utf8');
  } catch (e) {}
}

function saveTargetPosition(targetId, x, y) {
  const cfg = loadConfig();
  const positions = cfg.positions || {};
  positions[targetId] = { x, y };
  const updates = { positions };
  if (targetId === 'terminal') {
    updates.x = x;
    updates.y = y;
  }
  saveConfig(updates);
}

function getTargetDefaultPosition(targetId, screenWidth, screenHeight, cfg) {
  const positions = (cfg && cfg.positions) || {};
  if (positions[targetId] && positions[targetId].x != null && positions[targetId].y != null) {
    const px = positions[targetId].x;
    const py = positions[targetId].y;
    if (px >= 0 && (px + WINDOW_WIDTH) <= screenWidth && py >= 0 && (py + WINDOW_HEIGHT) <= screenHeight) {
      return { x: px, y: py };
    }
  }
  if (targetId === 'terminal' && cfg && cfg.x != null && cfg.y != null) {
    const px = cfg.x;
    const py = cfg.y;
    if (px >= 0 && (px + WINDOW_WIDTH) <= screenWidth && py >= 0 && (py + WINDOW_HEIGHT) <= screenHeight) {
      return { x: px, y: py };
    }
  }

  // Compute default positioning:
  // Terminal: right-side docked
  const termX = screenWidth - WINDOW_WIDTH - 24;
  const termY = Math.max(36, Math.round((screenHeight - WINDOW_HEIGHT) / 2));

  if (targetId === 'terminal') {
    return { x: termX, y: termY };
  }

  if (targetId === 'notes') {
    // If wide display, place side-by-side to the left of the terminal window
    if (screenWidth >= (WINDOW_WIDTH * 2 + 50)) {
      return {
        x: screenWidth - (WINDOW_WIDTH * 2) - 44,
        y: termY
      };
    } else {
      // Narrow display: offset cascade
      return {
        x: Math.max(12, termX - 60),
        y: Math.min(screenHeight - WINDOW_HEIGHT - 20, termY + 40)
      };
    }
  }

  // Any other target (e.g. textedit)
  return {
    x: Math.max(12, termX - 100),
    y: Math.min(screenHeight - WINDOW_HEIGHT - 20, termY + 60)
  };
}

function getOrCreateTargetInstance(targetId, targetName = null) {
  if (!targetInstances.has(targetId)) {
    const resolvedName = targetName || (targetId === 'notes' ? 'Notes' : (targetId === 'textedit' ? 'TextEdit' : 'Terminal'));
    const inst = new TargetInstance(targetId, resolvedName);
    targetInstances.set(targetId, inst);
    if (app.isReady()) {
      inst.window = createTargetWindow(targetId, resolvedName);
    }
    return inst;
  }
  const inst = targetInstances.get(targetId);
  if (targetName && inst.targetName !== targetName) {
    inst.targetName = targetName;
  }
  if (!inst.window || inst.window.isDestroyed()) {
    if (app.isReady()) {
      inst.window = createTargetWindow(targetId, inst.targetName);
    }
  }
  return inst;
}

function createTargetWindow(targetId, targetName) {
  configPath = path.join(app.getPath('userData'), 'gc-config.json');
  const cfg = loadConfig();

  const primaryDisplay = screen.getPrimaryDisplay();
  const { width: screenWidth, height: screenHeight } = primaryDisplay.workAreaSize;
  const pos = getTargetDefaultPosition(targetId, screenWidth, screenHeight, cfg);

  const win = new BrowserWindow({
    width: WINDOW_WIDTH,
    height: WINDOW_HEIGHT,
    minWidth: WINDOW_WIDTH,
    maxWidth: WINDOW_WIDTH,
    minHeight: WINDOW_HEIGHT,
    maxHeight: WINDOW_HEIGHT,
    x: pos.x,
    y: pos.y,
    frame: false,
    transparent: true,
    alwaysOnTop: false, // Default to false so other windows can overlay it when not actively typing
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    show: false, // Initially hidden until user begins typing in target
    skipTaskbar: false,
    hasShadow: false,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  if (process.platform === 'darwin') {
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  }

  win.webContents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return;

    const isMac = process.platform === 'darwin';
    const isUndo = (isMac ? input.meta : input.control) &&
                   !input.alt && !input.shift &&
                   (input.key.toLowerCase() === 'z' || input.code === 'KeyZ');
    if (isUndo) {
      const inst = targetInstances.get(targetId);
      if (inst && inst.isReviewMode) {
        event.preventDefault();
        handleUndoHotkey(targetId);
        return;
      }
    }

    const isCheck = (isMac ? (input.meta && input.shift) : (input.control && input.alt)) &&
                    (input.key.toLowerCase() === 'z' || input.code === 'KeyZ');
    if (isCheck) {
      const inst = targetInstances.get(targetId);
      if (inst && !inst.isReviewMode) {
        event.preventDefault();
        handleCheckHotkey(targetId);
        return;
      }
    }

    const isCopy = (isMac ? (input.meta && input.shift) : (input.control && input.alt)) &&
                   (input.key.toLowerCase() === 'x' || input.code === 'KeyX');
    if (isCopy) {
      event.preventDefault();
      handleHotkey();
      return;
    }
  });

  win.on('focus', () => {
    activeTargetId = targetId;
    // When the user clicks directly inside GC's HUD to copy or interact, elevate it only if alwaysOnTop is explicitly enabled
    if (isAlwaysOnTopEnabled) {
      if (process.platform === 'darwin') {
        win.setAlwaysOnTop(true, 'floating', 1);
      } else {
        win.setAlwaysOnTop(true);
      }
    } else {
      win.setAlwaysOnTop(false);
    }
  });

  win.on('blur', () => {
    if (!isAlwaysOnTopEnabled && win.isAlwaysOnTop()) {
      win.setAlwaysOnTop(false);
    }
  });

  win.loadFile('index.html', {
    query: {
      target: targetId,
      name: targetName
    }
  });

  win.on('will-resize', (e) => {
    e.preventDefault();
  });

  win.on('resize', () => {
    if (!win.isDestroyed()) {
      const [w, h] = win.getSize();
      if (w !== WINDOW_WIDTH || h !== WINDOW_HEIGHT) {
        win.setSize(WINDOW_WIDTH, WINDOW_HEIGHT);
      }
    }
  });

  let moveTimeout = null;
  win.on('moved', () => {
    if (moveTimeout) clearTimeout(moveTimeout);
    moveTimeout = setTimeout(() => {
      if (!win.isDestroyed()) {
        const [curX, curY] = win.getPosition();
        saveTargetPosition(targetId, curX, curY);
      }
    }, 500);
  });

  win.on('closed', () => {
    const inst = targetInstances.get(targetId);
    if (inst) {
      inst.window = null;
    }
  });

  return win;
}

function bringTargetToTop(targetId) {
  const inst = targetInstances.get(targetId);
  if (!inst || !inst.window || inst.window.isDestroyed()) return;

  // Multi-target isolation: lower all other target windows so only this active target's UI is on top
  for (const [tId, otherInst] of targetInstances) {
    if (tId !== targetId && otherInst.window && !otherInst.window.isDestroyed()) {
      if (otherInst.window.isAlwaysOnTop()) {
        otherInst.window.setAlwaysOnTop(false);
      }
    }
  }

  // Elevate this target's window only if alwaysOnTop is enabled, otherwise keep non-topmost so it never blocks other apps
  if (isAlwaysOnTopEnabled) {
    if (process.platform === 'darwin') {
      inst.window.setAlwaysOnTop(true, 'floating', 1);
    } else {
      inst.window.setAlwaysOnTop(true);
    }
  } else {
    if (inst.window.isAlwaysOnTop()) {
      inst.window.setAlwaysOnTop(false);
    }
  }

  // If window is popped, show inactive and move to top of z-order without stealing keyboard focus
  if (inst.isHoveringWindowPopped) {
    inst.window.showInactive();
    inst.window.moveTop();
  }
}

function lowerAllWindows() {
  for (const inst of targetInstances.values()) {
    if (inst.window && !inst.window.isDestroyed()) {
      if (inst.window.isAlwaysOnTop()) {
        inst.window.setAlwaysOnTop(false);
      }
    }
  }
}

function broadcastToAllWindows(channel, ...args) {
  for (const inst of targetInstances.values()) {
    if (inst.window && !inst.window.isDestroyed()) {
      inst.window.webContents.send(channel, ...args);
    }
  }
}

function switchDialect(dialect) {
  if (!dialect || !ollamaClient) return;
  ollamaClient.activeDialect = dialect;
  saveConfig({ activeDialect: dialect });
  console.log(`[GC] Switched active dialect to: ${dialect}`);
  updateTray();
  broadcastToAllWindows('dialect-changed', dialect);
}

function showHoveringWindow(targetId) {
  const inst = getOrCreateTargetInstance(targetId);
  if (!inst.window || inst.window.isDestroyed()) {
    inst.window = createTargetWindow(targetId, inst.targetName);
  }

  bringTargetToTop(targetId);
  inst.window.showInactive(); // Show window without stealing keyboard focus from target app
  inst.isHoveringWindowPopped = true;
  inst.window.webContents.send('window-popped', { targetId, targetName: inst.targetName });
  updateTray();
}

function hideHoveringWindow(targetId) {
  const inst = targetInstances.get(targetId);
  if (!inst) return;
  inst.isHoveringWindowPopped = false;
  inst.isReviewMode = false;
  inst.isCorrectionsUndone = false;
  inst.savedCorrectedText = '';
  inst.currentTypedText = '';
  inst.currentCorrectedText = '';
  inst.currentIssues = [];
  if (!isAnyWindowInReview()) {
    unregisterReviewUndoShortcut();
  }
  if (keyMonitor) {
    keyMonitor.clearBuffer(targetId);
  }
  if (inst.window && !inst.window.isDestroyed()) {
    inst.window.setAlwaysOnTop(false);
    inst.window.webContents.send('window-closed', { targetId });
    setTimeout(() => {
      if (!inst.isHoveringWindowPopped && inst.window && !inst.window.isDestroyed()) {
        inst.window.hide();
      }
    }, 200);
  }
  updateTray();
}

function showAndFocusForDirectInput(targetId) {
  const inst = getOrCreateTargetInstance(targetId);
  if (!inst.window || inst.window.isDestroyed()) {
    inst.window = createTargetWindow(targetId, inst.targetName);
  }

  // Preserve the linked application that was active before direct GC editor was opened
  if (inst.targetName && inst.targetName !== 'GC') {
    inst.linkedAppName = inst.targetName;
  }

  activeTargetId = targetId;
  inst.isHoveringWindowPopped = true;
  inst.isReviewMode = false;

  bringTargetToTop(targetId);
  inst.window.show();
  inst.window.focus();

  inst.window.webContents.send('focus-input-mode', {
    targetId: inst.targetId,
    targetName: inst.targetName
  });

  updateTray();
}

function pasteToLinkedApp(targetId) {
  const isMac = process.platform === 'darwin';
  if (isMac) {
    const inst = targetInstances.get(targetId);
    const targetName = (inst && (inst.linkedAppName || inst.targetName)) || (targetId === 'notes' ? 'Notes' : (targetId === 'textedit' ? 'TextEdit' : 'Terminal'));
    pasteToTargetMac(targetName);
  } else {
    if (keyMonitor) {
      keyMonitor.pasteToTarget(targetId);
    }
  }
}

function pasteToTargetMac(appName) {
  const { exec } = require('child_process');
  const appleScript = `
    tell application "System Events"
      set targetApp to "${appName}"
      set targetProc to missing value

      -- 1. Try matching the requested app process directly if running
      if targetApp is not "" and targetApp is not "Terminal" then
        set foundProcs to (every process whose name is targetApp)
        if (count of foundProcs) > 0 then
          set targetProc to first item of foundProcs
        end if
      end if

      -- 2. If target was generic Terminal or process wasn't found, check running terminals
      if targetProc is missing value then
        if targetApp is "Terminal" and (exists (first process whose name is "Terminal")) then
          set targetProc to first process whose name is "Terminal"
        else
          set candidateTerms to {"alacritty", "Alacritty", "iTerm2", "iTerm", "Warp", "kitty", "wezterm-gui", "wezterm", "ghostty", "CyberTerminal"}
          repeat with termName in candidateTerms
            set candidateProcs to (every process whose name is (termName as string))
            if (count of candidateProcs) > 0 then
              set targetProc to first item of candidateProcs
              exit repeat
            end if
          end repeat
        end if
      end if

      -- 3. If a target process was found, bring it to front without launching closed apps
      if targetProc is not missing value then
        set frontmost of targetProc to true
        delay 0.08
      end if

      -- 4. Send paste keystroke
      keystroke "v" using command down
    end tell
  `;
  exec(`osascript -e '${appleScript.replace(/'/g, "'\\''")}'`, (err) => {
    if (err) console.error('[GC] Error pasting to Mac target:', err);
  });
}

function copyCorrectedTextForTarget(targetInst) {
  if (!targetInst) return;
  const textToCopy = (targetInst.currentCorrectedText && targetInst.currentCorrectedText.trim())
    ? targetInst.currentCorrectedText.trim()
    : (targetInst.currentTypedText ? targetInst.currentTypedText.trim() : '');

  if (textToCopy) {
    clipboard.writeText(textToCopy);
    console.log(`[GC] Copied corrected text for ${targetInst.targetId}:`, textToCopy);
  }

  if (targetInst.window && !targetInst.window.isDestroyed()) {
    targetInst.window.webContents.send('copied-feedback', { targetId: targetInst.targetId, text: textToCopy });
  }

  // Automatically activate the linked app and paste the corrected text!
  pasteToLinkedApp(targetInst.targetId);

  // Per user requirements: GC's UI stays visible after copying/pasting.
  // It only disappears when Enter key is pressed in the terminal to submit the prompt.
}

function isAnyWindowPopped() {
  for (const inst of targetInstances.values()) {
    if (inst.isHoveringWindowPopped) return true;
  }
  return false;
}

function findTargetBySender(sender) {
  for (const [targetId, inst] of targetInstances) {
    if (inst.window && !inst.window.isDestroyed() && inst.window.webContents === sender) {
      return inst;
    }
  }
  return targetInstances.get(activeTargetId) || targetInstances.get('terminal');
}

// -------------------------------------------------------------
// Hotkey State Machine: Shift + Command + X (Mac) / Ctrl + Alt + X (Win)
// Rule A: Under Input Mode, pressing Copy opens GC's UI and focuses it for direct input.
// Rule B: After Check hotkey has been pressed (Review Mode), pressing Copy copies corrected text.
// -------------------------------------------------------------
function handleHotkey() {
  if (!keyMonitor) return;

  if (!isGCRunning) {
    isGCRunning = true;
    keyMonitor.startRecording();
    updateTray();
    broadcastToAllWindows('gc-running-state', { isGCRunning: true, isHoveringWindowPopped: false });
    console.log('[GC] Started (isGCRunning = true). Monitoring Terminal, Notes, etc.');
  }

  // Resolve target instance
  let targetInst = targetInstances.get(activeTargetId);
  if (!targetInst || !targetInst.isHoveringWindowPopped) {
    for (const inst of targetInstances.values()) {
      if (inst.isHoveringWindowPopped) {
        targetInst = inst;
        break;
      }
    }
  }

  if (!targetInst) {
    targetInst = getOrCreateTargetInstance(activeTargetId || 'terminal');
  }

  // If in Review Mode (after Check hotkey was triggered), copy the corrected text
  if (targetInst.isHoveringWindowPopped && targetInst.isReviewMode) {
    copyCorrectedTextForTarget(targetInst);
    return;
  }

  // Otherwise, user selects to type inside GC's UI under Input Mode
  showAndFocusForDirectInput(targetInst.targetId);
}

// -------------------------------------------------------------
// Review Mode Undo State Machine: Ctrl + Z (Win) / Cmd + Z (Mac)
// Allows user to revert corrections and copy original inputs
// -------------------------------------------------------------
let isUndoShortcutRegistered = false;

function isAnyWindowInReview() {
  for (const inst of targetInstances.values()) {
    if (inst.isHoveringWindowPopped && inst.isReviewMode) return true;
  }
  return false;
}

function registerReviewUndoShortcut() {
  if (isUndoShortcutRegistered) return;
  const isMac = process.platform === 'darwin';
  const undoKey = isMac ? 'Command+Z' : 'CommandOrControl+Z';
  try {
    const ok = globalShortcut.register(undoKey, () => {
      handleUndoHotkey();
    });
    if (ok) isUndoShortcutRegistered = true;
  } catch (e) {
    console.error('[GC] Failed to register review undo shortcut:', e);
  }
}

function unregisterReviewUndoShortcut() {
  if (!isUndoShortcutRegistered) return;
  const isMac = process.platform === 'darwin';
  const undoKey = isMac ? 'Command+Z' : 'CommandOrControl+Z';
  try {
    globalShortcut.unregister(undoKey);
  } catch (e) {}
  isUndoShortcutRegistered = false;
}

let lastUndoHotkeyTime = 0;

function handleUndoHotkey(targetIdOverride = null) {
  const now = Date.now();
  if (now - lastUndoHotkeyTime < 300) {
    return; // Cooldown: prevent concurrent duplicate triggers from multiple handlers
  }
  lastUndoHotkeyTime = now;

  const targetId = targetIdOverride || activeTargetId;
  let targetInst = targetInstances.get(targetId);
  if (!targetInst || !targetInst.isHoveringWindowPopped || !targetInst.isReviewMode) {
    for (const inst of targetInstances.values()) {
      if (inst.isHoveringWindowPopped && inst.isReviewMode) {
        targetInst = inst;
        break;
      }
    }
  }

  if (!targetInst || !targetInst.isHoveringWindowPopped || !targetInst.isReviewMode) {
    return;
  }

  // Undo corrections: return GC to Input Mode and revert to original input
  targetInst.isReviewMode = false;
  targetInst.isCorrectionsUndone = false;
  targetInst.savedCorrectedText = '';
  targetInst.currentCorrectedText = targetInst.currentTypedText;
  targetInst.currentIssues = [];

  console.log(`[GC] Undo: Reverted corrections for ${targetInst.targetId}. Returned to Input Mode: "${targetInst.currentTypedText}"`);

  if (!isAnyWindowInReview()) {
    unregisterReviewUndoShortcut();
  }

  if (targetInst.window && !targetInst.window.isDestroyed()) {
    targetInst.window.webContents.send('undo-to-input-mode', {
      targetId: targetInst.targetId,
      originalText: targetInst.currentTypedText
    });
  }
}

// -------------------------------------------------------------
// Hotkey: Shift + Command + Z (Mac) / Ctrl + Alt + Z (Win)
// Signal that user finished typing, and begin review
// -------------------------------------------------------------
function handleCheckHotkey(targetIdOverride = null) {
  if (!isGCRunning) {
    console.log('[GC] Review hotkey pressed, but GC is not active.');
    return;
  }

  const targetId = targetIdOverride || activeTargetId;
  let inst = targetInstances.get(targetId);
  if (!inst || !inst.currentTypedText.trim()) {
    for (const [tId, tInst] of targetInstances) {
      if (tInst.isHoveringWindowPopped && tInst.currentTypedText.trim()) {
        inst = tInst;
        break;
      }
    }
  }

  if (!inst) return;
  const textToCheck = (inst.currentTypedText || '').trim();
  if (!textToCheck) {
    console.log(`[GC] Review hotkey pressed, but no typed text for target ${inst.targetId}.`);
    return;
  }

  inst.isReviewMode = true;
  inst.isCorrectionsUndone = false;
  registerReviewUndoShortcut();

  if (!inst.isHoveringWindowPopped) {
    showHoveringWindow(inst.targetId);
  } else {
    bringTargetToTop(inst.targetId);
  }

  console.log(`[GC] Finished typing hotkey triggered for target ${inst.targetId} (${inst.targetName}):`, textToCheck);
  triggerOllamaCorrection(inst.targetId, textToCheck);
}

async function triggerOllamaCorrection(targetId, text) {
  const inst = targetInstances.get(targetId);
  if (!inst) return;

  const analysisId = ++inst.currentAnalysisId;
  const trimmed = (text || '').trim();

  if (!trimmed || trimmed.length < 2) {
    inst.savedCorrectedText = text;
    inst.currentCorrectedText = text;
    inst.isCorrectionsUndone = false;
    if (inst.window && !inst.window.isDestroyed()) {
      inst.window.webContents.send('correction-result', {
        targetId,
        text,
        corrected: text,
        issues: [],
        status: 'clean'
      });
    }
    return;
  }

  if (inst.window && !inst.window.isDestroyed()) {
    inst.window.webContents.send('correction-checking', { targetId });
  }

  try {
    const result = await ollamaClient.checkGrammarAndSpelling(trimmed);
    if (analysisId !== inst.currentAnalysisId) return; // Stale request, discard

    if (result && result.success) {
      let safeCorrected = result.corrected || trimmed;
      if (typeof safeCorrected === 'string' && (
        safeCorrected.startsWith('{"') ||
        safeCorrected.startsWith('`') ||
        safeCorrected.includes('"issues":') ||
        safeCorrected.includes('"replacement":') ||
        safeCorrected.includes('"model":')
      )) {
        safeCorrected = trimmed;
      }

      inst.savedCorrectedText = safeCorrected;
      inst.currentCorrectedText = safeCorrected;
      inst.currentIssues = result.issues || [];
      inst.isCorrectionsUndone = false;
      if (inst.window && !inst.window.isDestroyed()) {
        inst.window.webContents.send('correction-result', {
          targetId,
          text: trimmed,
          corrected: safeCorrected,
          issues: result.issues || [],
          durationMs: result.durationMs,
          dialect: result.dialect || (ollamaClient ? ollamaClient.activeDialect : 'en-GB'),
          status: (result.issues && result.issues.length > 0) ? 'corrected' : 'clean'
        });
      }
    } else {
      inst.savedCorrectedText = trimmed;
      inst.currentCorrectedText = trimmed;
      inst.isCorrectionsUndone = false;
      if (inst.window && !inst.window.isDestroyed()) {
        inst.window.webContents.send('correction-result', {
          targetId,
          text: trimmed,
          corrected: trimmed,
          issues: [],
          status: 'error',
          error: result?.error
        });
      }
    }
  } catch (err) {
    if (analysisId !== inst.currentAnalysisId) return;
    inst.currentCorrectedText = trimmed;
  }
}

async function checkClipboardText() {
  const clipText = clipboard.readText().trim();
  if (clipText) {
    const targetId = activeTargetId || 'terminal';
    const inst = getOrCreateTargetInstance(targetId);
    if (!inst.isHoveringWindowPopped) {
      showHoveringWindow(targetId);
    }
    inst.currentTypedText = clipText;
    inst.currentCorrectedText = clipText;
    if (inst.window && !inst.window.isDestroyed()) {
      inst.window.webContents.send('typing-update', {
        targetId,
        targetName: inst.targetName,
        text: clipText,
        length: clipText.length,
        words: clipText.split(/\s+/).length
      });
    }
    triggerOllamaCorrection(targetId, clipText);
  }
}

function resetAllWindowPositions() {
  const primary = screen.getPrimaryDisplay();
  const { width: screenWidth, height: screenHeight } = primary.workAreaSize;
  const positions = {};
  for (const [targetId, inst] of targetInstances) {
    const defPos = getTargetDefaultPosition(targetId, screenWidth, screenHeight, null);
    positions[targetId] = defPos;
    if (inst.window && !inst.window.isDestroyed()) {
      inst.window.setPosition(defPos.x, defPos.y);
    }
  }
  saveConfig({ positions, x: positions.terminal?.x, y: positions.terminal?.y });
}

function querySTStatus() {
  return new Promise((resolve) => {
    const req = http.get('http://127.0.0.1:11435/status', { timeout: 800 }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          resolve({ running: true, enabled: !!json.enabled, model: json.model });
        } catch (e) {
          resolve({ running: false, enabled: false });
        }
      });
    });
    req.on('error', () => resolve({ running: false, enabled: false }));
    req.on('timeout', () => { req.destroy(); resolve({ running: false, enabled: false }); });
  });
}

function toggleST() {
  http.get('http://127.0.0.1:11435/toggle', { timeout: 1000 }, () => {
    setTimeout(updateTray, 200);
  }).on('error', () => {});
}

function testSTPopup() {
  http.get('http://127.0.0.1:11435/test', { timeout: 1000 }, () => {}).on('error', () => {});
}

function quitGCSTSuite() {
  app.isQuitting = true;
  try {
    http.get('http://127.0.0.1:11435/quit', { timeout: 500 }, () => {}).on('error', () => {});
  } catch (e) {}

  setTimeout(() => {
    try {
      const { exec } = require('child_process');
      exec('pkill -f "ST.app/Contents/MacOS/ST" || true');
    } catch (e) {}
    app.quit();
  }, 200);
}

function getTrayIcon(active = false) {
  if (process.platform === 'darwin') {
    const templateName = active ? 'gcstTemplateActive.png' : 'gcstTemplate.png';
    const templatePath = path.join(__dirname, 'assets', templateName);
    if (fs.existsSync(templatePath)) {
      const img = nativeImage.createFromPath(templatePath);
      img.setTemplateImage(true);
      return img;
    }
  }

  // Windows 11 & cross-platform: Use the exact same stacked GC-over-ST design as macOS
  if (process.platform === 'win32') {
    const icoName = active ? 'gcstTemplateActive.ico' : 'gcstTemplate.ico';
    const icoPath = path.join(__dirname, 'assets', icoName);
    if (fs.existsSync(icoPath)) {
      const img = nativeImage.createFromPath(icoPath);
      if (!img.isEmpty()) return img;
    }
  }

  const templateName = active ? 'gcstTemplateActive.png' : 'gcstTemplate.png';
  const templatePath = path.join(__dirname, 'assets', templateName);
  if (fs.existsSync(templatePath)) {
    return nativeImage.createFromPath(templatePath);
  }

  const iconName = active ? 'gcst-icon-active.png' : 'gcst-icon.png';
  let iconPath = path.join(__dirname, 'assets', iconName);
  if (!fs.existsSync(iconPath)) {
    iconPath = path.join(__dirname, 'assets', active ? 'icon-recording.png' : 'icon.png');
  }
  let icon = nativeImage.createFromPath(iconPath);
  if (process.platform === 'darwin') {
    icon = icon.resize({ width: 18, height: 18 });
  }
  return icon;
}

function createTray() {
  const icon = getTrayIcon(isGCRunning);

  tray = new Tray(icon);
  tray.setToolTip('GCST Suite: British Grammar Checker (GC) & Hover Translator (ST)');
  updateTray();

  tray.on('click', () => {
    const anyPopped = isAnyWindowPopped();
    if (anyPopped) {
      for (const inst of targetInstances.values()) {
        if (inst.window && !inst.window.isDestroyed() && inst.isHoveringWindowPopped) {
          inst.window.focus();
        }
      }
    } else {
      showHoveringWindow(activeTargetId || 'terminal');
    }
    updateTray();
  });

  tray.on('double-click', () => {
    showHoveringWindow(activeTargetId || 'terminal');
    updateTray();
  });
}

async function updateTray() {
  if (!tray) return;

  const icon = getTrayIcon(isGCRunning);
  tray.setImage(icon);

  const targetDesc = process.platform === 'darwin'
    ? 'Terminal / Notes / iTerm2 / Warp'
    : 'Terminal / CyberTerminal / Notepad';
  const hotkeyDesc = process.platform === 'darwin' ? 'Shift+Cmd+X' : 'Ctrl+Alt+X';

  const statusTooltip = `GCST Suite [GC: ${isGCRunning ? 'ON' : 'OFF'} | ST: Active]`;
  tray.setToolTip(statusTooltip);

  let stStatus = { running: false, enabled: false };
  try {
    stStatus = await querySTStatus();
  } catch (e) {}

  let availableModels = ['gemma4:e4b'];
  let isOllamaOnline = false;
  try {
    isOllamaOnline = await ollamaClient.checkHealth();
    availableModels = await ollamaClient.getAvailableModels();
    if (availableModels.length === 0) availableModels = ['gemma4:e4b'];
  } catch (e) {}

  const modelMenuItems = availableModels.map(m => ({
    label: m,
    type: 'radio',
    checked: m === ollamaClient.activeModel,
    click: () => {
      ollamaClient.activeModel = m;
      saveConfig({ activeModel: m });
      broadcastToAllWindows('model-changed', m);
      updateTray();
    }
  }));

  const anyPopped = isAnyWindowPopped();

  const contextMenu = Menu.buildFromTemplate([
    {
      label: 'GCST Suite (Unified AI Desktop)',
      enabled: false
    },
    { type: 'separator' },

    // --- GC Grammar & Spell Checker ---
    {
      label: `GC Grammar Checker: ${isGCRunning ? 'ACTIVE (On)' : 'STANDBY (Off)'}`,
      enabled: false
    },
    {
      label: isGCRunning ? 'Turn Off GC' : `Turn On GC (${hotkeyDesc})`,
      click: () => {
        if (isGCRunning) {
          isGCRunning = false;
          if (keyMonitor) keyMonitor.stopRecording();
          for (const [tId] of targetInstances) {
            hideHoveringWindow(tId);
          }
          updateTray();
          broadcastToAllWindows('gc-running-state', { isGCRunning: false, isHoveringWindowPopped: false });
          console.log('[GC] Stopped via tray.');
        } else {
          isGCRunning = true;
          if (keyMonitor) keyMonitor.startRecording();
          updateTray();
          broadcastToAllWindows('gc-running-state', { isGCRunning: true, isHoveringWindowPopped: false });
          console.log('[GC] Started via tray.');
        }
      }
    },
    {
      label: anyPopped ? 'Hide GC HUD' : 'Open GC HUD',
      click: () => {
        if (anyPopped) {
          for (const [tId] of targetInstances) {
            hideHoveringWindow(tId);
          }
        } else {
          showHoveringWindow('terminal');
        }
      }
    },
    {
      label: 'GC English Dialect',
      submenu: [
        {
          label: 'British English (en-GB)',
          type: 'radio',
          checked: !ollamaClient || ollamaClient.activeDialect === 'en-GB',
          click: () => switchDialect('en-GB')
        },
        {
          label: 'American English (en-US)',
          type: 'radio',
          checked: !!ollamaClient && ollamaClient.activeDialect === 'en-US',
          click: () => switchDialect('en-US')
        },
        {
          label: 'Australian English (en-AU)',
          type: 'radio',
          checked: !!ollamaClient && ollamaClient.activeDialect === 'en-AU',
          click: () => switchDialect('en-AU')
        },
        {
          label: 'Chinglish (en-CN) [Fun Mode]',
          type: 'radio',
          checked: !!ollamaClient && ollamaClient.activeDialect === 'en-CN',
          click: () => switchDialect('en-CN')
        }
      ]
    },
    { type: 'separator' },

    // --- ST Hover Translator ---
    {
      label: `ST Hover Translator: ${stStatus.running ? (stStatus.enabled ? 'ACTIVE (On)' : 'DISABLED (Paused)') : 'OFF (Not Running)'}`,
      enabled: false
    },
    {
      label: stStatus.enabled ? 'Pause ST Hover Translation' : 'Resume ST Hover Translation',
      enabled: stStatus.running,
      click: () => toggleST()
    },
    {
      label: 'Test ST Translation Popup',
      enabled: stStatus.running,
      click: () => testSTPopup()
    },
    { type: 'separator' },

    // --- Shared LLM Backend (Ollama) ---
    {
      label: 'Shared Model (Ollama)',
      submenu: modelMenuItems
    },
    {
      label: `Ollama: ${isOllamaOnline ? 'Online (127.0.0.1:11434)' : 'Offline'}`,
      enabled: false
    },
    {
      label: 'Check System Clipboard in GC',
      click: () => {
        checkClipboardText();
      }
    },
    {
      label: 'Always on Top (GC HUD)',
      type: 'checkbox',
      checked: isAlwaysOnTopEnabled,
      click: () => {
        isAlwaysOnTopEnabled = !isAlwaysOnTopEnabled;
        saveConfig({ alwaysOnTop: isAlwaysOnTopEnabled });
        for (const inst of targetInstances.values()) {
          if (inst.window && !inst.window.isDestroyed()) {
            if (isAlwaysOnTopEnabled) {
              if (process.platform === 'darwin') {
                inst.window.setAlwaysOnTop(true, 'floating', 1);
              } else {
                inst.window.setAlwaysOnTop(true);
              }
            } else {
              inst.window.setAlwaysOnTop(false);
            }
          }
        }
        updateTray();
      }
    },
    { type: 'separator' },
    {
      label: 'Quit GCST Suite',
      click: () => {
        quitGCSTSuite();
      }
    }
  ]);

  tray.setContextMenu(contextMenu);
}

app.whenReady().then(async () => {
  configPath = path.join(app.getPath('userData'), 'gc-config.json');
  const cfg = loadConfig();
  isAlwaysOnTopEnabled = !!cfg.alwaysOnTop;
  ollamaClient = new OllamaClient('http://127.0.0.1:11434', cfg.activeModel || 'gemma4:e4b', cfg.activeDialect || 'en-GB');
  await ollamaClient.resolveBestModel();

  // Pre-initialize Terminal and Notes windows
  getOrCreateTargetInstance('terminal', 'Terminal');
  getOrCreateTargetInstance('notes', 'Notes');

  createTray();

  // Configure application menu with review-aware Undo/Redo handling
  const menuTemplate = [
    ...(isMac ? [{
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' }
      ]
    }] : []),
    {
      label: 'Edit',
      submenu: [
        {
          label: 'Undo',
          accelerator: 'CmdOrCtrl+Z',
          click: () => {
            if (isAnyWindowInReview()) {
              handleUndoHotkey();
            } else {
              const focused = BrowserWindow.getFocusedWindow();
              if (focused) focused.webContents.undo();
            }
          }
        },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' }
      ]
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(menuTemplate));

  // Initialize KeyMonitor
  try {
    keyMonitor = new KeyMonitorManager();
    keyMonitor.start();

    keyMonitor.on('update', ({ target, targetName, text, length, words }) => {
      if (!isGCRunning) return;

      activeTargetId = target || 'terminal';
      const inst = getOrCreateTargetInstance(activeTargetId, targetName);
      inst.currentTypedText = text || '';

      // Once the user has resumed typing in the window, bring GC's UI to the top!
      bringTargetToTop(activeTargetId);

      if (text && text.trim().length > 0) {
        if (!inst.isHoveringWindowPopped) {
          showHoveringWindow(activeTargetId);
        }

        if (inst.window && !inst.window.isDestroyed()) {
          inst.window.webContents.send('typing-update', {
            targetId: activeTargetId,
            targetName: inst.targetName,
            text,
            length,
            words
          });
        }
      } else {
        inst.currentTypedText = '';
        inst.currentCorrectedText = '';
        inst.currentIssues = [];
        if (inst.window && !inst.window.isDestroyed()) {
          inst.window.webContents.send('typing-update', {
            targetId: activeTargetId,
            targetName: inst.targetName,
            text: '',
            length: 0,
            words: 0
          });
        }
      }
    });

    keyMonitor.on('action', ({ target, targetName, action }) => {
      if (action === 'enter') {
        // In Terminal, Enter submits prompt -> dismiss that target's hovering window
        hideHoveringWindow(target || 'terminal');
      } else if (action === 'undo') {
        handleUndoHotkey(target);
      }
    });

    keyMonitor.on('target_closed', ({ target }) => {
      console.log(`[GC] Tracked target window closed: ${target}`);
      hideHoveringWindow(target || 'terminal');
    });

    keyMonitor.on('focus', ({ target, targetName }) => {
      activeTargetId = target || 'terminal';
      const inst = getOrCreateTargetInstance(activeTargetId, targetName);
      if (inst.isHoveringWindowPopped) {
        bringTargetToTop(activeTargetId);
      }
    });

    keyMonitor.on('blur', () => {
      // User switched away to another application window to view or read: allow other windows to overlay GC's UI!
      lowerAllWindows();
    });

    keyMonitor.on('error', (err) => {
      console.error('KeyMonitor error:', err);
    });
  } catch (err) {
    console.error('Failed to start KeyMonitor:', err);
  }

  // Register Global Hotkeys
  // macOS: Shift + Command + X & Shift + Command + Z
  // Windows: Ctrl + Alt + X & Ctrl + Alt + Z
  const hotkeyX = isMac ? 'Command+Shift+X' : 'CommandOrControl+Alt+X';
  const hotkeyZ = isMac ? 'Command+Shift+Z' : 'CommandOrControl+Alt+Z';

  // 1. Power / Copy Corrected / Standby
  const retX = globalShortcut.register(hotkeyX, () => {
    handleHotkey();
  });
  if (!retX) {
    console.error(`Registration of ${hotkeyX} failed!`);
  }

  // 2. Finished typing -> Trigger Grammar Check
  const retZ = globalShortcut.register(hotkeyZ, () => {
    handleCheckHotkey();
  });
  if (!retZ) {
    console.error(`Registration of ${hotkeyZ} failed!`);
  }

  // Set macOS Dock Icon if available
  if (process.platform === 'darwin' && app.dock) {
    const dockIconPath = path.join(__dirname, 'assets', 'icon.png');
    if (fs.existsSync(dockIconPath)) {
      app.dock.setIcon(dockIconPath);
    }
  }

  // Setup IPC Handlers
  ipcMain.on('manual-hotkey-trigger', () => {
    handleHotkey();
  });

  ipcMain.on('trigger-check-manual', (event, data) => {
    const targetId = (data && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const inst = targetInstances.get(targetId);
    if (inst && data && typeof data.text === 'string') {
      inst.currentTypedText = data.text;
    }
    handleCheckHotkey(targetId);
  });

  ipcMain.on('manual-typing-input', (event, data) => {
    const targetId = (data && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const text = data && data.text !== undefined ? data.text : '';
    const inst = targetInstances.get(targetId);
    if (inst) {
      inst.currentTypedText = text;
      inst.isReviewMode = false;
      if (keyMonitor) {
        keyMonitor.clearBuffer(targetId);
      }
    }
  });

  ipcMain.on('set-input-mode', (event, data) => {
    const targetId = (data && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const inst = targetInstances.get(targetId);
    if (inst) {
      inst.isReviewMode = false;
      inst.isCorrectionsUndone = false;
    }
    if (!isAnyWindowInReview()) {
      unregisterReviewUndoShortcut();
    }
  });

  ipcMain.on('undo-corrections', (event, data) => {
    const targetId = (data && data.targetId) || findTargetBySender(event.sender)?.targetId;
    handleUndoHotkey(targetId);
  });

  ipcMain.on('update-corrected-text', (event, data) => {
    const text = typeof data === 'object' ? data.text : data;
    const targetId = (typeof data === 'object' && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const inst = targetInstances.get(targetId);
    if (inst) {
      inst.currentCorrectedText = text || '';
    }
  });

  ipcMain.on('copy-corrected-text', (event, data) => {
    const text = typeof data === 'object' ? data.text : data;
    const targetId = (typeof data === 'object' && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const inst = targetInstances.get(targetId);
    if (inst) {
      if (text && text.trim()) {
        inst.currentCorrectedText = text.trim();
      }
      copyCorrectedTextForTarget(inst);
    }
  });

  ipcMain.on('close-hovering-window', (event, data) => {
    const targetId = (data && data.targetId) || findTargetBySender(event.sender)?.targetId;
    if (targetId) {
      hideHoveringWindow(targetId);
    }
  });

  ipcMain.on('clear-buffer-manual', (event, data) => {
    const targetId = (data && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const inst = targetInstances.get(targetId);
    if (inst) {
      inst.currentTypedText = '';
      inst.currentCorrectedText = '';
      inst.currentIssues = [];
      if (keyMonitor) {
        keyMonitor.clearBuffer(targetId);
      }
      if (inst.window && !inst.window.isDestroyed()) {
        inst.window.webContents.send('typing-update', {
          targetId,
          targetName: inst.targetName,
          text: '',
          length: 0,
          words: 0
        });
      }
    }
  });

  ipcMain.on('check-clipboard-manual', () => {
    checkClipboardText();
  });

  ipcMain.on('paste-manual', (event, data) => {
    const text = typeof data === 'object' ? data.text : data;
    const targetId = (typeof data === 'object' && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const inst = targetInstances.get(targetId);
    if (inst && text && text.trim()) {
      inst.currentTypedText = text;
      inst.currentCorrectedText = '';
      inst.currentIssues = [];
      if (inst.window && !inst.window.isDestroyed()) {
        inst.window.webContents.send('typing-update', {
          targetId,
          targetName: inst.targetName,
          text,
          length: text.length,
          words: text.split(/\s+/).length
        });
      }
    }
  });

  ipcMain.on('get-available-models', async (event) => {
    let models = [];
    try {
      models = await ollamaClient.getAvailableModels();
      models = models.filter(m => !m.toLowerCase().includes('embedding'));
      if (models.length === 0) models = ['gemma4:e4b'];
    } catch (e) {
      models = ['gemma4:e4b'];
    }
    event.reply('available-models-result', {
      models,
      activeModel: ollamaClient ? ollamaClient.activeModel : 'gemma4:e4b'
    });
  });

  ipcMain.on('switch-model', (event, modelName) => {
    if (modelName && ollamaClient) {
      ollamaClient.activeModel = modelName;
      saveConfig({ activeModel: modelName });
      console.log(`[GC] Switched active model to: ${modelName}`);
      updateTray();
      broadcastToAllWindows('model-changed', modelName);
    }
  });

  ipcMain.on('switch-dialect', (event, dialect) => {
    switchDialect(dialect);
  });

  ipcMain.on('get-app-state', (event, data) => {
    const targetId = (data && data.targetId) || findTargetBySender(event.sender)?.targetId;
    const inst = targetInstances.get(targetId);
    event.reply('app-state', {
      targetId,
      targetName: inst ? inst.targetName : 'Terminal',
      isGCRunning,
      isHoveringWindowPopped: inst ? inst.isHoveringWindowPopped : false,
      activeModel: ollamaClient ? ollamaClient.activeModel : 'gemma4:e4b',
      activeDialect: ollamaClient ? ollamaClient.activeDialect : 'en-GB',
      typedText: inst ? inst.currentTypedText : '',
      correctedText: inst ? inst.currentCorrectedText : ''
    });
  });

  ipcMain.on('window-move', (event, { deltaX, deltaY, targetId }) => {
    const inst = targetId ? targetInstances.get(targetId) : findTargetBySender(event.sender);
    if (inst && inst.window && !inst.window.isDestroyed()) {
      const [x, y] = inst.window.getPosition();
      inst.window.setPosition(x + deltaX, y + deltaY);
    }
  });

  ipcMain.on('window-set-position', (event, { x, y, targetId }) => {
    const inst = targetId ? targetInstances.get(targetId) : findTargetBySender(event.sender);
    if (inst && inst.window && !inst.window.isDestroyed()) {
      const primary = screen.getPrimaryDisplay();
      const { width: screenWidth, height: screenHeight } = primary.workAreaSize;
      const clampedX = Math.max(0, Math.min(x, screenWidth - WINDOW_WIDTH));
      const clampedY = Math.max(0, Math.min(y, screenHeight - WINDOW_HEIGHT));
      inst.window.setPosition(Math.round(clampedX), Math.round(clampedY));
    }
  });
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  if (keyMonitor) {
    keyMonitor.destroy();
  }
});

app.on('window-all-closed', () => {
  // Keep running in tray
});
