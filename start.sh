#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-all}"
MODE_LOWER="$(echo "$MODE" | tr '[:upper:]' '[:lower:]')"

echo "============================================================"
echo "  GCST Suite - Unified AI Desktop Suite (macOS)"
echo "  GC: British English Grammar Checker"
echo "  ST: Real-Time On-Screen Hover Translator"
echo "============================================================"

# 1. Health probe for local Ollama
echo ""
echo "[1/3] Probing local Ollama service (127.0.0.1:11434)..."
if command -v curl &>/dev/null; then
    TAGS_OUTPUT=$(curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || true)
    if [ -n "$TAGS_OUTPUT" ]; then
        echo "  [OK] Ollama is online at 127.0.0.1:11434"
        if echo "$TAGS_OUTPUT" | grep -q "gemma4:e4b"; then
            echo "  [OK] Model 'gemma4:e4b' is available."
        else
            echo "  [!] Notice: 'gemma4:e4b' was not found in local models list."
            echo "      Recommended: ollama pull gemma4:e4b"
        fi
    else
        echo "  [!] Warning: Ollama service is not responding at 127.0.0.1:11434"
        echo "      Please ensure Ollama is started with: ollama serve"
    fi
else
    echo "  [!] curl not found, skipping Ollama pre-flight check."
fi

start_gc() {
    echo ""
    echo "[2/3] Preparing GC (British Grammar & Spell Checker)..."
    (
        cd "$SCRIPT_DIR/GC"

        # Check and install node dependencies if missing
        if [ ! -d "node_modules" ] || [ ! -f "node_modules/.bin/electron" ]; then
            echo "  [*] Installing GC dependencies via npm..."
            npm install
        fi

        # Check and compile native KeyMonitor_mac hook
        if [ ! -f "bin/KeyMonitor_mac" ] || [ "src/KeyMonitor_mac.m" -nt "bin/KeyMonitor_mac" ]; then
            echo "  [*] Compiling GC KeyMonitor_mac hook..."
            mkdir -p bin
            clang -O2 -framework Cocoa -framework ApplicationServices -framework Carbon src/KeyMonitor_mac.m -o bin/KeyMonitor_mac
        fi
        chmod +x bin/KeyMonitor_mac 2>/dev/null || true

        echo "  [->] Launching GC..."
        nohup ./node_modules/.bin/electron . </dev/null >/tmp/gc_electron.log 2>&1 &
        echo "  [OK] GC launched in background (active in desktop HUD & system tray)."
    )
}

start_st() {
    echo ""
    echo "[3/3] Preparing ST (On-Screen Hover Translator)..."
    (
        cd "$SCRIPT_DIR/ST"
        chmod +x build.sh 2>/dev/null || true
        chmod +x bin/ST 2>/dev/null || true

        # Check if bundle executable exists and is valid
        if [ ! -f "ST.app/Contents/MacOS/ST" ]; then
            echo "  [*] Compiling ST app bundle..."
            ./build.sh
        else
            chmod +x "ST.app/Contents/MacOS/ST" 2>/dev/null || true
        fi

        echo "  [->] Launching ST..."
        if [ -d "ST.app" ]; then
            open "$SCRIPT_DIR/ST/ST.app"
        elif [ -f "bin/ST" ]; then
            nohup "$SCRIPT_DIR/ST/bin/ST" >/dev/null 2>&1 &
        else
            ./build.sh
            open "$SCRIPT_DIR/ST/ST.app"
        fi
        echo "  [OK] ST launched in background (active in menu bar & hover detection)."
    )
}

case "$MODE_LOWER" in
    all)
        start_gc
        start_st
        ;;
    gc)
        start_gc
        ;;
    st)
        start_st
        ;;
    *)
        echo "Usage: ./start.sh [all|gc|st]"
        exit 1
        ;;
esac

echo ""
echo "============================================================"
echo "  GCST components active!"
echo "  To stop: run ./stop.sh or 'npm run stop'"
echo "============================================================"
