@echo off
cd /d "%~dp0"

echo [ST] Starting ST On-Screen Hover Translator...

if not exist ".venv\Scripts\python.exe" (
    echo [ST] Creating virtual environment...
    uv venv .venv
    echo [ST] Installing dependencies...
    uv pip install --python .venv\Scripts\python.exe -r requirements.txt
)

echo [ST] Launching ST in background (Standalone)...
start "" ".venv\Scripts\pythonw.exe" -m st_windows.main --standalone
echo [ST] Running in System Tray!
