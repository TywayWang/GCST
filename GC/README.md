# GC // Real-Time British English Grammar & Spell Checker

**GC** is an intelligent, offline, floating British English (en-GB / Oxford standard) grammar and spell checker designed for macOS and Windows. It is powered locally by **Gemma 4** via **Ollama**.

---

## Highlights

1. **Target Filtering & Multi-Window Management**:
   - Actively monitors typing only in focused target windows:
     - **macOS:** Apple Terminal (`Terminal.app`), Apple Notes (`com.apple.Notes`), iTerm2, Warp, Alacritty, Kitty, WezTerm, Ghostty, CyberTerminal, and TextEdit.
     - **Windows:** Windows Terminal (`wt.exe`), PowerShell, Command Prompt, Alacritty, Warp, Git Bash, CyberTerminal, and Notepad.
   - When typing in both Terminal and Notes, GC automatically manages independent floating HUD windows for each application with isolated buffers, cursor positions, and review states.
   - All other background applications, system shortcuts, and general windows are completely ignored.

2. **Terminal Line-Editing & Text Editor Support**:
   - Maintains an accurate internal cursor matching your terminal shell or notes document.
   - Automatically handles standard terminal line editing hotkeys:
     - `Ctrl + U` / `Cmd + Backspace`: Line kill backward (wipes all typed input back to prompt start).
     - `Ctrl + K`: Kill forward to end of line.
     - `Option + Backspace` / `Alt + Backspace` / `Ctrl + W`: Backward kill word.
     - `Option + Delete` / `Alt + Delete` / `Ctrl + Delete`: Forward kill word.
     - `Ctrl + A` / `Cmd + Left` / `Home` & `Ctrl + E` / `Cmd + Right` / `End`: Beginning / end of line navigation.
     - `Option + Left` / `Option + B` / `Ctrl + Left`: Word navigation backward.
     - `Option + Right` / `Option + F` / `Ctrl + Right`: Word navigation forward.
     - `Cmd + V` / `Ctrl + V` / `Ctrl + Shift + V` / `Shift + Insert` & Terminal Right-Click: Clipboard paste recognition.
     - `Enter`: Submits terminal command, clears buffer, and dismisses the terminal HUD. In Notes, `Enter` seamlessly creates newlines (`\n`) for long-form writing without dismissing the HUD.

3. **Dual Input Methods & Flexible Typing Location**:
   - **Terminal / Editor Tracking**: Type directly inside your focused terminal (Windows Terminal, CMD, PowerShell, CyberTerminal, Notepad, Notes, etc.) and GC automatically tracks input without stealing focus.
   - **Direct GC Editor Input**: Press the **Copy** hotkey (`Ctrl + Alt + X` / `Shift + Cmd + X`) to pop open GC's window and focus directly in GC's Editor. Under Input Mode, users can type, delete, jump around, and modify words anywhere (including ahead of the cursor) with native browser-grade fidelity, avoiding out-of-sync cursor issues.
   - Click the input stage badge (`[Terminal]` ⟷ `[GC Editor]`) anytime to switch input focus manually.

4. **Dual Hotkey Workflow**:
   - **`Shift + Cmd + X` (macOS) / `Ctrl + Alt + X` (Windows)** *(Open, Direct Input & Copy)*:
     - *Under Input Mode (First Press / Standby)*: Opens GC's UI, elevates it to the front, and focuses GC's Editor directly so the user can immediately type inside GC.
     - *Under Review Mode (After Check Hotkey)*: Copies the corrected British English text directly to the system clipboard, automatically activates the linked target application (Terminal, CyberTerminal, Notepad, Notes), directly pastes the text into it, and dismisses the HUD.
   - **`Shift + Cmd + Z` (macOS) / `Ctrl + Alt + Z` (Windows)** *(Finished Typing -> Review)*:
     - Signals that typing is finished and immediately triggers local Gemma 4 review on the active text.
     - Enters Review Mode with inline Grammarly-style replacement pills.
     - Alternatively, press `Ctrl + Enter` / `Cmd + Enter` inside the GC Editor to trigger review.

---

## Hotkey Quick Reference

| Action | macOS Shortcut | Windows 11 Shortcut | Context |
|---|---|---|---|
| **Open GC & Direct Input** | **`Shift + Cmd + X`** | **`Ctrl + Alt + X`** | Input Mode (opens UI & focuses editor) |
| **Review English** | **`Shift + Cmd + Z`** | **`Ctrl + Alt + Z`** | Finished typing (or `Ctrl+Enter`) |
| **Delete Ahead of Cursor** | **`Control + U`** | **`Ctrl + U`** | GC Editor (removes all text ahead / left of cursor) |
| **Delete Behind Cursor** | **`Control + K`** | **`Ctrl + K`** | GC Editor (removes all text behind / right of cursor) |
| **Undo Corrections** | **`Cmd + Z`** | **`Ctrl + Z`** | Review Mode (undoes corrections & returns to Input Mode) |
| **Copy & Auto-Paste** | **`Shift + Cmd + X`** | **`Ctrl + Alt + X`** | Review Mode (copies & auto-pastes to linked app) |
| **Turn ON / OFF** | System Tray Menu | System Tray Menu | Background state toggle |

---

## Privacy & Local-First Architecture

GC is built strictly as a **100% private, local-first utility**:

- **No Remote Telemetry or Network Calls**: GC makes zero calls to remote servers, analytics, or third-party cloud APIs. All AI grammar inference is processed locally on your machine via [Ollama](https://ollama.ai) (`http://127.0.0.1:11434`).
- **RAM-Only Keystroke Buffering**: Typed keystrokes are kept strictly in volatile memory (RAM) while typing in designated target apps. Keystrokes are never logged to disk, temporary files, or any external storage.
- **Strict Target Window Isolation**: The low-level hook inspects the foreground process ID and window title before registering any keystroke. Keystrokes typed into browsers, password fields, chat applications, or any non-target windows are instantly ignored and never captured.

---

## File Structure

```
GC/
├── assets/
│   ├── icon.png                 # System tray normal icon
│   ├── icon-recording.png       # Active state tray icon
│   ├── icon.svg
│   └── icon-recording.svg
├── bin/
│   ├── KeyMonitor_mac           # High-performance native macOS CoreGraphics hook (arm64/x86_64)
│   └── KeyMonitor.exe           # High-performance native Windows C# low-level hook
├── src/
│   ├── KeyMonitor_mac.m         # macOS Objective-C low-level hook & target filter
│   ├── KeyMonitor.cs            # Windows C# low-level hook & target filter
│   ├── keyMonitorManager.cjs    # Cross-platform Node.js process manager
│   └── ollamaClient.cjs         # Dialect prompts & Ollama API client
├── main.cjs                     # Electron main process (multi-target state machine, tray, global shortcuts)
├── index.html                   # Draggable hovering HUD UI
├── styles.css                   # Obsidian glassmorphic design system
├── renderer.js                  # Frontend state, pointer capture drag, and audio synth
├── package.json
├── start.sh                     # macOS launcher
├── start.bat                    # Windows launcher
├── LICENSE                      # MIT License
└── README.md
```

---

## How to Run

### On macOS:
1. Ensure Ollama is running locally with the Gemma 4 model (`ollama serve` or background service on `http://127.0.0.1:11434`).
2. Run in this directory:
   ```bash
   ./start.sh
   # or
   npm start
   ```

### On Windows:
1. Ensure Ollama is running locally with the Gemma 4 model (`ollama serve` on `http://127.0.0.1:11434`).
2. Run in this directory:
   ```cmd
   start.bat
   # or
   npm start
   ```

---

## Building Native Hooks From Source

For users who prefer to audit and compile the low-level hooks themselves:

- **macOS (`bin/KeyMonitor_mac`)**:
  ```bash
  npm run build-mac-hook
  ```
  *(Uses `clang -O2 -framework Cocoa -framework ApplicationServices -framework Carbon src/KeyMonitor_mac.m -o bin/KeyMonitor_mac && chmod +x bin/KeyMonitor_mac`)*

- **Windows (`bin/KeyMonitor.exe`)**:
  ```cmd
  npm run compile-hook
  ```
  *(Uses Microsoft .NET Framework C# compiler `csc.exe /target:exe /out:bin\KeyMonitor.exe /r:System.Windows.Forms.dll src\KeyMonitor.cs`)*

---

## License

[MIT License](LICENSE) © 2026 Dr. TywayWang
