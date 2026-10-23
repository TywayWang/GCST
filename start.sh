#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-all}"

echo "============================================================"
echo "  GCST Suite - Unified AI Desktop Suite (macOS)"
echo "  GC: British English Grammar Checker"
echo "  ST: Real-Time On-Screen Hover Translator"
echo "============================================================"

# Health probe for Ollama
if command -v curl &>/dev/null; then
    if curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        echo "[OK] Ollama is online at 127.0.0.1:11434"
    else
        echo "[!] Warning: Ollama not responding at 127.0.0.1:11434"
    fi
fi

start_gc() {
    echo "[GCST] Starting GC..."
    (
        cd "$SCRIPT_DIR/GC"
        if [ ! -f "bin/KeyMonitor_mac" ]; then
            echo "[GC] Compiling KeyMonitor_mac..."
            clang -O2 -framework Cocoa -framework ApplicationServices -framework Carbon src/KeyMonitor_mac.m -o bin/KeyMonitor_mac
            chmod +x bin/KeyMonitor_mac
        fi
        npm start &
    )
}

start_st() {
    echo "[GCST] Starting ST..."
    (
        cd "$SCRIPT_DIR/ST"
        if [ -d "ST.app" ]; then
            open ST.app
        elif [ -f "bin/ST" ]; then
            ./bin/ST &
        else
            echo "[ST] Compiling ST app bundle..."
            ./build.sh
            open ST.app
        fi
    )
}

case "$MODE" in
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

echo "[GCST] Requested component(s) started."
