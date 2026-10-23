# GCST

**Unified British English Grammar & Spell Checker (GC) and On-Screen Hover Translator (ST) Desktop Suite**

GCST merges two local desktop AI productivity tools into a unified, modular ecosystem powered by local **Gemma 4** (`gemma4:e4b`) via **Ollama**.

---

## 🏗️ Architecture & Modular Separation

GC and ST are maintained as completely decoupled, self-contained sub-ecosystems under `GCST/`. Each component possesses its own dependencies, runtime configuration, hooks, and interface processes, coordinated via root orchestration runners.

```
GCST/
├── GC/                        # British English Grammar & Spell Checker Subsystem
│   ├── assets/                # Icons and visual assets
│   ├── bin/                   # Compiled low-level native hooks
│   │   ├── KeyMonitor.exe     # Windows WH_KEYBOARD_LL low-level hook
│   │   └── KeyMonitor_mac     # macOS CGEventTap native hook
│   ├── node_modules/          # Electron & Node runtime dependencies
│   ├── src/                   # Core application logic & Ollama client
│   │   ├── KeyMonitor.cs      # C# keyboard hook source
│   │   ├── KeyMonitor_mac.m   # Objective-C keyboard hook source
│   │   ├── keyMonitorManager.cjs # Inter-process hook orchestrator
│   │   └── ollamaClient.cjs   # Ollama Gemma 4 API client with structured JSON parsing
│   ├── index.html             # Floating correction HUD layout
│   ├── main.cjs               # Electron main process (z-order HUD, tray management)
│   ├── renderer.js            # HUD interactivity & keyboard navigation
│   ├── styles.css             # Cyberpunk minimalist dark HUD styling
│   ├── package.json           # Subsystem npm scripts & electron config
│   └── start.bat              # Standalone GC launcher
│
├── ST/                        # On-Screen Hover Translator Subsystem
│   ├── .venv/                 # Isolated Python 3.12 virtual environment (managed by uv)
│   ├── bin/                   # Pre-compiled native macOS binary
│   │   └── ST                 # macOS universal arm64 binary
│   ├── Resources/             # macOS App bundle resources (Info.plist)
│   ├── Sources/               # macOS Native Swift + SwiftUI implementation
│   ├── st_windows/            # Windows 11 Native Python + PyQt6 + UIAutomation implementation
│   │   ├── config.py          # Configuration manager (config.json)
│   │   ├── logger.py          # Unified logging
│   │   ├── main.py            # App coordinator & process entry
│   │   ├── ollama_service.py  # Async Ollama Gemma 4 streaming client
│   │   ├── selection_monitor.py # Win32 / pynput mouse hover & selection detector
│   │   ├── text_extractor.py  # UIAutomation & clipboard fallback extraction
│   │   ├── translation_window.py # Floating non-activating acrylic translation popup
│   │   └── tray_app.py        # System tray menu & quick settings
│   ├── tests/                 # Component & integration test suite
│   ├── config.json            # Hover delay, model, and language preferences
│   ├── requirements.txt       # Windows Python dependencies
│   ├── run_windows.bat        # Standalone ST launcher
│   └── run_windows.ps1        # Standalone ST PowerShell runner
│
├── scripts/                   # Cross-platform runner helpers
│   ├── start.cjs              # Node runner dispatcher
│   └── stop.cjs               # Node stopper dispatcher
│
├── start.bat                  # Master Windows 1-Click Interactive / CLI Launcher
├── stop.bat                   # Master Windows Process Stopper (targeted PID cleanup)
├── start.ps1                  # Master PowerShell Orchestrator
├── stop.ps1                   # Master PowerShell Stopper
├── start.sh                   # Master macOS Orchestrator
├── stop.sh                    # Master macOS Stopper
├── package.json               # Root npm scripts
├── .gitignore                 # Unified gitignore
└── README.md                  # Suite documentation
```

---

## ⚡ Components

### 1. `GC` (British English Grammar & Spell Checker)
* **Real-Time Terminal & Text Interception**: Actively tracks keystrokes in Windows Terminal, PowerShell, CMD, CyberTerminal, and Notepad via a native C# hook (`KeyMonitor.exe`).
* **British English Localization**: Enforces standard Oxford/Cambridge spelling (e.g. *colour*, *analyse*, *catalogue*, *behaviour*), punctuation, and tone.
* **Non-Blocking Minimalist HUD**: Displays non-activating floating suggestions right above your cursor without stealing active window focus or blocking other apps.
* **Hotkeys**:
  * <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>X</kbd>: Trigger instant grammar check on buffered text.
  * <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>Z</kbd>: Instant undo / revert correction.
  * <kbd>Enter</kbd> (in HUD): Apply suggested correction.
  * <kbd>Esc</kbd> (in HUD): Dismiss HUD.

### 2. `ST` (On-Screen Hover Translator)
* **Hover Text Translation**: Highlight any text in any application (browser, PDF, code editor, office apps) and hover your cursor for ~350ms. A sleek translation panel floats above your selection.
* **Acrylic Non-Activating Window**: Uses `WS_EX_NOACTIVATE` and `Qt.WindowType.ToolTip` so target windows retain keyboard and focus state.
* **Pin & Copy**: Includes pin lock button to keep translation open for detailed reading, plus 1-click clipboard copy.
* **Multilingual Flexibility**: Configurable Source (`Auto`, `English`, `Chinese`, etc.) and Target language via System Tray or `config.json`.

---

## 🧠 Shared Local LLM Backend

Both applications communicate with your local **Ollama** instance:
* **Host / Port**: `http://127.0.0.1:11434`
* **Model**: `gemma4:e4b`
* **Zero Cloud Latency / 100% Privacy**: All grammar inspection and text translations happen locally on your GPU/CPU without transmitting text off your workstation.

---

## 🚀 Quick Start

### Windows 11

#### Option A: Master 1-Click Launcher (Recommended)
Double-click `start.bat` in the root folder to open the interactive menu:
```text
============================================================
     GCST - Unified AI Desktop Suite Launcher
============================================================
  [1] Launch Both (GC + ST) in Background
  [2] Launch GC Only (British Grammar & Spell Checker)
  [3] Launch ST Only (On-Screen Hover Translator)
  [4] Stop Running GCST Processes
  [5] Exit
============================================================
```

Or pass command-line arguments:
```cmd
# Launch both components in background
start.bat all

# Launch GC only
start.bat gc

# Launch ST only
start.bat st

# Stop all running GCST processes
stop.bat
```

#### Option B: PowerShell
```powershell
# Launch both in background
.\start.ps1 -Component All

# Launch individual components
.\start.ps1 -Component GC
.\start.ps1 -Component ST

# Terminate GCST processes safely
.\stop.ps1 -Component All
```

#### Option C: NPM Scripts
```bash
# Launch both
npm start

# Launch individually
npm run start:gc
npm run start:st

# Stop
npm run stop
```

---

### macOS

```bash
# Launch both
./start.sh all

# Launch individually
./start.sh gc
./start.sh st

# Stop
./stop.sh all
```

---

## 🛑 Process Control & Safety

The suite includes path-targeted termination scripts (`stop.bat`, `stop.ps1`, `stop.sh`). They selectively inspect process working directories and paths matching `GCST`, ensuring other running developer tools, editor windows, or independent project instances are never affected.

---

## 📜 License
MIT
