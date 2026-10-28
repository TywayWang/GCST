import sys
import os
import signal
import ctypes
from PyQt6.QtCore import Qt, QObject, pyqtSignal, QTimer, QMetaObject
from PyQt6.QtWidgets import QApplication

from .logger import st_log
from .ollama_service import OllamaService
from .text_extractor import TextExtractor
from .selection_monitor import SelectionMonitor
from .translation_window import TranslationWindow
from .tray_app import TrayApp
from .ipc_server import STIPCServer
from .config import load_config

class AppCoordinator(QObject):
    """Coordinates events between SelectionMonitor, TextExtractor, and TranslationWindow."""
    text_ready = pyqtSignal(str)

    def __init__(self, monitor: SelectionMonitor, window: TranslationWindow):
        super().__init__()
        self.monitor = monitor
        self.window = window
        self.extractor = TextExtractor.shared()

        # Connect signals
        self.monitor.translation_requested.connect(self._on_translation_requested)
        self.monitor.dismiss_requested.connect(self._on_dismiss_requested)
        self.text_ready.connect(self._on_text_ready)

        # Wire callbacks for monitor state checks
        self.monitor.is_panel_visible = lambda: self.window.isVisible()
        self.monitor.is_panel_pinned = lambda: self.window.is_pinned
        self.monitor.is_point_inside_panel = lambda x, y: self.window.is_point_inside(x, y)

    def _on_translation_requested(self):
        st_log("Coordinator: translation_requested")
        def on_extracted(extracted: str | None):
            if extracted:
                st_log(f"Coordinator: Extracted text length {len(extracted)}. Emitting text_ready.")
                self.text_ready.emit(extracted)
            else:
                st_log("Coordinator: No translatable text found.")

        self.extractor.extract_selected_text(on_extracted)

    def _on_text_ready(self, text: str):
        st_log(f"Coordinator: Showing translation window for '{text[:40]}'")
        self.window.show_translation(text)
        if hasattr(self.monitor, 'start_esc_listener'):
            self.monitor.start_esc_listener()

    def _on_dismiss_requested(self):
        if self.window.isVisible() and not self.window.is_pinned:
            st_log("Coordinator: Dismissing translation window")
            if hasattr(self.monitor, 'stop_esc_listener'):
                self.monitor.stop_esc_listener()
            self.window.dismiss()


def main():
    # Set Windows App User Model ID so Windows handles taskbar/tray grouping properly
    try:
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("tywaywang.st.translator.win")
    except Exception:
        pass

    # Ensure UTF-8 output
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

    st_log("Starting ST on-screen hover translator for Windows 11...")

    # Load persisted settings
    cfg = load_config()
    model_name = cfg.get("model", "gemma4:e4b")
    hover_delay = cfg.get("hover_delay", 0.35)
    move_dismiss_radius = cfg.get("move_dismiss_radius", 100.0)

    OllamaService.shared().set_model(model_name)

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    window = TranslationWindow()
    window.set_model_name(model_name)

    monitor = SelectionMonitor(hover_delay=hover_delay, move_dismiss_radius=move_dismiss_radius)
    coordinator = AppCoordinator(monitor, window)

    # Wire pause toggle callback between TranslationWindow and SelectionMonitor
    def on_pause_toggled(is_paused: bool):
        monitor.is_enabled = not is_paused
        if tray:
            tray.on_paused_state_changed(is_paused)
        try:
            import urllib.request
            req = urllib.request.Request("http://127.0.0.1:11436/st-status-updated")
            urllib.request.urlopen(req, timeout=0.5)
        except Exception:
            pass
        st_log(f"Coordinator: Hover translation {'paused' if is_paused else 'resumed'}")

    window.pause_toggled_callback = on_pause_toggled

    # Check standalone mode vs GCST unified suite mode (matching macOS ST behavior)
    is_standalone = "--standalone" in sys.argv or os.environ.get("ST_STANDALONE") == "1"

    tray = None
    if is_standalone:
        tray = TrayApp(app, monitor, window)
        window.model_changed.connect(tray.on_model_changed_external)
        st_log("ST running in standalone mode (system tray icon active)")
    else:
        st_log("Running in unified GCST suite mode: task tray icon is handled by GCST")

    # Start internal IPC command listener on port 11435 for GCST suite coordination
    ipc_server = STIPCServer(monitor, window, app, port=11435)
    ipc_server.start()

    monitor.start()

    # 1. Console Ctrl+C handler for Windows PowerShell / CMD
    def win32_console_ctrl_handler(ctrl_type):
        st_log(f"Console interrupt event ({ctrl_type}) received. Exiting ST cleanly...")
        ipc_server.stop()
        monitor.stop()
        window.dismiss()
        QMetaObject.invokeMethod(app, "quit", Qt.ConnectionType.QueuedConnection)
        return True

    try:
        import win32api
        win32api.SetConsoleCtrlHandler(win32_console_ctrl_handler, True)
    except Exception as e:
        st_log(f"Notice setting console ctrl handler: {e}")

    # 2. Python SIGINT signal handler
    def sigint_handler(signum, frame):
        st_log("SIGINT (Ctrl+C) received. Exiting ST cleanly...")
        ipc_server.stop()
        monitor.stop()
        window.dismiss()
        app.quit()

    try:
        signal.signal(signal.SIGINT, sigint_handler)
    except Exception:
        pass

    # 3. Heartbeat timer to periodically yield control to Python interpreter
    heartbeat_timer = QTimer()
    heartbeat_timer.timeout.connect(lambda: None)
    heartbeat_timer.start(200)

    mode_desc = "Standalone System Tray" if is_standalone else "Unified GCST Suite"
    st_log(f"ST for Windows 11 initialized and running in {mode_desc} mode (Model: {model_name}, Move-Dismiss: {move_dismiss_radius}px).")
    sys.exit(app.exec())

if __name__ == "__main__":
    main()
