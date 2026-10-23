#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

# Ensure macOS native hook is compiled
if [ ! -f "bin/KeyMonitor_mac" ]; then
  echo "[GC] Compiling macOS native KeyMonitor hook..."
  clang -O2 -framework Cocoa -framework ApplicationServices -framework Carbon src/KeyMonitor_mac.m -o bin/KeyMonitor_mac
  chmod +x bin/KeyMonitor_mac
fi

# Ensure executable permission
chmod +x bin/KeyMonitor_mac 2>/dev/null

echo "[GC] Starting GC (macOS build)..."
npm start
