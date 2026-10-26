import json
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from PyQt6.QtCore import QObject, pyqtSignal
from .logger import st_log
from .ollama_service import OllamaService


class IPCBridge(QObject):
    """Bridge to invoke Qt GUI methods safely on the main Qt thread."""
    trigger_test = pyqtSignal()
    trigger_quit = pyqtSignal()


class STIPCServer:
    def __init__(self, monitor, window, app, port: int = 11435):
        self.monitor = monitor
        self.window = window
        self.app = app
        self.port = port
        self.httpd = None
        self.thread = None

        self.bridge = IPCBridge()
        self.bridge.trigger_test.connect(self._do_test)
        self.bridge.trigger_quit.connect(self._do_quit)

    def _do_test(self):
        st_log("STIPCServer: Executing test popup on GUI thread")
        sample_text = (
            "Quantum entanglement is a physical phenomenon that occurs when "
            "a group of particles are generated, interact, or share spatial proximity."
        )
        self.window.show_center(sample_text)
        if hasattr(self.monitor, 'start_esc_listener'):
            self.monitor.start_esc_listener()

    def _do_quit(self):
        st_log("STIPCServer: Executing quit on GUI thread")
        self.monitor.stop()
        self.window.dismiss()
        self.app.quit()

    def start(self):
        parent = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                # Suppress verbose default HTTP server logs
                pass

            def do_GET(self):
                clean_path = self.path.split("?")[0]
                status_code = 200
                response_data = {"ok": True}

                if clean_path == "/status":
                    model = OllamaService.shared().model_name
                    enabled = parent.monitor.is_enabled if parent.monitor else False
                    response_data = {"running": True, "enabled": enabled, "model": model}

                elif clean_path == "/toggle":
                    if parent.monitor:
                        parent.monitor.is_enabled = not parent.monitor.is_enabled
                        enabled = parent.monitor.is_enabled
                    else:
                        enabled = False
                    st_log(f"STIPCServer: toggle -> is_enabled={enabled}")
                    response_data = {"enabled": enabled}

                elif clean_path == "/test":
                    st_log("STIPCServer: received /test request")
                    parent.bridge.trigger_test.emit()
                    response_data = {"test": True}

                elif clean_path == "/quit":
                    st_log("STIPCServer: received /quit request")
                    parent.bridge.trigger_quit.emit()
                    response_data = {"quit": True}

                else:
                    status_code = 404
                    response_data = {"error": "Not Found"}

                body = json.dumps(response_data).encode("utf-8")
                self.send_response(status_code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

        try:
            self.httpd = HTTPServer(("127.0.0.1", self.port), Handler)
            self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
            self.thread.start()
            st_log(f"STIPCServer: Command listener active on http://127.0.0.1:{self.port}")
        except Exception as e:
            st_log(f"STIPCServer: Failed to start command listener on port {self.port}: {e}")

    def stop(self):
        if self.httpd:
            try:
                self.httpd.shutdown()
                self.httpd.server_close()
            except Exception:
                pass
            self.httpd = None
