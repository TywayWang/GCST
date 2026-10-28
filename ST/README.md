# ST — On-Screen Hover Translator (Windows 11 & macOS)

**ST** is a lightweight, zero-friction on-screen floating HUD translator powered by a local **Gemma 4** model (`gemma4:e4b`) running on **Ollama**.

Inspired by the Obsidian `deepseek-translator` plugin, **ST** brings seamless hover translation to **all desktop applications**—including **Obsidian** (reading `.pdf` or markdown), **Microsoft Edge / Google Chrome**, **Adobe Acrobat / PDF readers**, **Apple Books**, code editors, and native windows.

---

## ✨ Features & User Experience

Follows your exact 3-step reading workflow:
1. **Select**: Left-click and drag across any word, sentence, or paragraph (or double/triple-click).
2. **Hover**: Let your cursor hover over the selected text (default ~350ms).
3. **Pop-up**: A frosted glass HUD box pops out directly **above the selected content** with the Simplified Chinese translation streaming in real-time from your local Gemma 4 model.

### Key Highlights
- **Focus Preservation**: Built as a non-activating floating panel (`WS_EX_NOACTIVATE` on Windows 11, `NSPanel` with `.nonactivatingPanel` on macOS). It **never steals keyboard focus** from Obsidian, PDF viewers, or browsers, so your text highlight and reading flow remain completely uninterrupted.
- **Universal App Support**: Dual text extraction strategy:
  1. *UI Automation & Accessibility API* (`IUIAutomation` on Windows, `AXUIElement` on macOS): Instant zero-touch text extraction.
  2. *Synthetic Copy with Smart Restoration*: Automatically falls back for Electron apps (Obsidian PDF), WebKit, and complex document canvases, then restores your original clipboard contents so your copied links/snippets are never lost.
- **Local & Private**: Powered by your local Ollama instance (`http://localhost:11434`) using `gemma4:e4b`. 100% offline, zero data leaves your PC.
- **Real-Time Streaming**: Chinese translations stream in token-by-token with sub-second latency (~250ms–550ms).
- **Interactive Controls**:
  - ⏸ / ▶ **Pause / Resume Button**: Instantly pause or resume hover translation directly from the translation window header.
  - ⚡ **Free VRAM Button**: One-click GPU VRAM release by unloading active Ollama models.
  - 📌 **Pin Button**: Pin the popup window so it stays visible while you take notes.
  - 📋 **Copy Button**: One-click copy of the Chinese translation to clipboard with visual "Copied" feedback.
  - ✕ **Close / Esc**: Instantly dismisses the popup (also auto-dismisses when you move your cursor away or click outside).
- **System Tray / Menu Bar Control**:
  - Live Ollama health check (`gemma4:e4b ✓ Online`).
  - **Dynamic Model Selection**: Switch seamlessly between any locally deployed Ollama LLM (`gemma4:e4b`, `translator:latest`, `qwen3:8b`, etc.) directly from the System Tray. Choices persist across restarts.
  - Toggle hover translation On/Off.
  - Adjustable hover delay (250ms, 350ms, 500ms, 700ms).
  - Auto-dismiss on cursor move with comfortable 100px radius.
  - Test popup translation item.

---

## 🚀 Quick Start

### Windows 11

#### Prerequisites
- [Ollama](https://ollama.com) installed and running with `gemma4:e4b`:
  ```cmd
  ollama run gemma4:e4b
  ```
- Python 3.10+ (or [uv](https://github.com/astral-sh/uv))

#### Launching on Windows
Double-click `run_windows.bat` or run via PowerShell:

```powershell
cd F:\Projects\appDev\ST

# One-step launch (automatically sets up .venv and dependencies)
.\run_windows.bat

# Or using PowerShell runner directly:
.\run_windows.ps1
```

Once launched, ST will appear in your **Windows System Tray** (notification area) with live status.

---

### macOS

#### Build & Run
```bash
cd /Users/tyweywang/appDev/ST

# Build ST.app and binary
make build

# Launch the app
make run

# Stop ST
make stop
```

Alternatively, launch `ST.app` directly from Finder or Terminal:
```bash
open /Users/tyweywang/appDev/ST/ST.app
```

---

## 🛠 Project Structure

```
F:\Projects\appDev\ST/
├── st_windows/                 # Windows 11 Native Client (PyQt6 + Win32 + UIAutomation)
│   ├── __init__.py             # Package metadata
│   ├── main.py                 # Windows entry point & coordinator
│   ├── logger.py               # Diagnostics logger
│   ├── ollama_service.py       # Ollama streaming client with NDJSON parser
│   ├── text_extractor.py       # UIAutomation + Ctrl+C fallback with clipboard restoration
│   ├── selection_monitor.py    # Global mouse drag & hover detection state machine
│   ├── translation_window.py   # Non-activating floating frosted glass HUD (WS_EX_NOACTIVATE)
│   └── tray_app.py             # Windows System Tray icon & context menu
├── Sources/                    # macOS Native Client (Swift + AppKit + SwiftUI)
│   ├── main.swift              # App entry point, menu-bar agent configuration
│   ├── AppDelegate.swift       # Menu bar status item, delegate coordination
│   ├── OllamaService.swift     # Ollama API client with streaming NDJSON parser
│   ├── TextExtractor.swift     # AXUIElement + Cmd+C fallback with clipboard restoration
│   ├── SelectionMonitor.swift  # Mouse drag & hover detection state machine
│   ├── TranslationPanel.swift  # Non-activating floating panel positioned above selection
│   └── TranslationView.swift   # SwiftUI frosted glass HUD with streaming text & actions
├── tests/                      # Component and UI regression test suite
├── requirements.txt            # Windows Python dependencies
├── pyproject.toml              # Modern Python packaging configuration
├── run_windows.bat             # Windows 1-click batch launcher
├── run_windows.ps1             # Windows PowerShell launcher
├── build.sh                    # macOS swiftc build script
├── Makefile                    # macOS make build / run / stop / clean
└── README.md                   # Documentation
```

---

## ⚙️ Configuration & Customization

- **Ollama Host**: Default is `http://127.0.0.1:11434`.
- **Model**: Default is `gemma4:e4b` (also compatible with `translator:latest`, `qwen3:8b`, etc.).
- **Hover Delay**: Configurable from the System Tray / Menu Bar item (default: 350ms).
