#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-all}"
MODE_LOWER="$(echo "$MODE" | tr '[:upper:]' '[:lower:]')"

echo "============================================================"
echo "  GCST Suite - Stopping Processes (macOS)"
echo "============================================================"

stop_gc() {
    echo "[GCST] Stopping GC instances..."
    pkill -f "$SCRIPT_DIR/GC" || true
    pkill -f "KeyMonitor_mac" || true
}

stop_st() {
    echo "[GCST] Stopping ST instances..."
    osascript -e 'quit app "ST"' 2>/dev/null || true
    pkill -f "ST.app/Contents/MacOS/ST" || true
    pkill -f "$SCRIPT_DIR/ST/bin/ST" || true
}

case "$MODE_LOWER" in
    all)
        stop_gc
        stop_st
        ;;
    gc)
        stop_gc
        ;;
    st)
        stop_st
        ;;
    *)
        echo "Usage: ./stop.sh [all|gc|st]"
        exit 1
        ;;
esac

echo "[GCST] Stopped."
