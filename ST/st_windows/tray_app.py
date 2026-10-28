import sys
from typing import Optional, List

from PyQt6.QtCore import Qt, QPoint, QObject, pyqtSignal
from PyQt6.QtGui import (
    QIcon, QPixmap, QPainter, QColor, QFont, QLinearGradient, QAction, QActionGroup
)
from PyQt6.QtWidgets import (
    QSystemTrayIcon, QMenu, QApplication
)

from .logger import st_log
from .ollama_service import OllamaService
from .selection_monitor import SelectionMonitor
from .translation_window import TranslationWindow
from .config import load_config, save_config

def create_tray_icon() -> QIcon:
    """Dynamically generates a crisp, high-DPI ST tray icon with blue-purple gradient."""
    size = 64
    pixmap = QPixmap(size, size)
    pixmap.fill(Qt.GlobalColor.transparent)

    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)

    gradient = QLinearGradient(0, 0, size, size)
    gradient.setColorAt(0.0, QColor("#2563eb"))
    gradient.setColorAt(1.0, QColor("#7c3aed"))

    painter.setBrush(gradient)
    painter.setPen(Qt.PenStyle.NoPen)
    painter.drawRoundedRect(4, 4, size - 8, size - 8, 14, 14)

    font = QFont("Segoe UI", 24, QFont.Weight.Black)
    painter.setFont(font)
    painter.setPen(QColor("#ffffff"))
    painter.drawText(pixmap.rect(), Qt.AlignmentFlag.AlignCenter, "ST")

    painter.end()
    return QIcon(pixmap)


class TrayApp(QObject):
    models_fetched = pyqtSignal(list)

    def __init__(
        self,
        app: QApplication,
        selection_monitor: SelectionMonitor,
        translation_window: TranslationWindow
    ):
        super().__init__()
        self.app = app
        self.selection_monitor = selection_monitor
        self.translation_window = translation_window
        self.config = load_config()

        self.models_fetched.connect(self._handle_models_fetched)

        self.tray_icon = QSystemTrayIcon(create_tray_icon(), self.app)
        self.tray_icon.setToolTip("ST: English-to-Chinese Hover Translator")

        self.model_actions_group: Optional[QActionGroup] = None
        self._init_menu()
        self.tray_icon.show()

        # Initial Ollama health check & model discovery
        self.check_ollama()

    def _init_menu(self):
        menu = QMenu()
        menu.setStyleSheet("""
            QMenu {
                background-color: #1e1e24;
                color: #e2e8f0;
                border: 1px solid #334155;
                border-radius: 8px;
                padding: 4px;
            }
            QMenu::item {
                padding: 6px 20px 6px 12px;
                border-radius: 4px;
            }
            QMenu::item:selected {
                background-color: #3b82f6;
                color: #ffffff;
            }
            QMenu::separator {
                height: 1px;
                background-color: #334155;
                margin: 4px 8px;
            }
        """)

        # Title Item
        title_action = QAction("ST Translator", menu)
        title_action.setEnabled(False)
        menu.addAction(title_action)

        menu.addSeparator()

        # Active Toggle Action
        self.active_action = QAction(
            "Pause ST Hover Translation" if self.selection_monitor.is_enabled else "Resume ST Hover Translation",
            menu
        )
        self.active_action.setCheckable(True)
        self.active_action.setChecked(self.selection_monitor.is_enabled)
        self.active_action.triggered.connect(self._toggle_active)
        menu.addAction(self.active_action)

        # Ollama Status Action
        self.ollama_action = QAction("Ollama: Checking...", menu)
        self.ollama_action.triggered.connect(self.check_ollama)
        menu.addAction(self.ollama_action)

        # Model Selection Submenu
        self.model_menu = menu.addMenu("Model")
        self._populate_model_menu([])

        menu.addSeparator()

        # Hover Delay Submenu
        delay_menu = menu.addMenu("Hover Delay")
        delay_group = QActionGroup(delay_menu)
        delay_group.setExclusive(True)

        for delay_val in [0.25, 0.35, 0.50, 0.70]:
            action = QAction(f"{int(delay_val * 1000)} ms", delay_menu)
            action.setCheckable(True)
            if abs(delay_val - self.selection_monitor.hover_delay) < 0.01:
                action.setChecked(True)
            action.triggered.connect(lambda checked, d=delay_val: self._set_hover_delay(d))
            delay_group.addAction(action)
            delay_menu.addAction(action)

        # Test Translation Action
        test_action = QAction("Test Popup Translation", menu)
        test_action.triggered.connect(self._test_popup)
        menu.addAction(test_action)

        # Free VRAM Action
        free_vram_action = QAction("⚡ Free up VRAM", menu)
        free_vram_action.setToolTip("Unload active LLM models from GPU VRAM")
        free_vram_action.triggered.connect(self._free_vram)
        menu.addAction(free_vram_action)

        menu.addSeparator()

        # Quit Action
        quit_action = QAction("Quit ST", menu)
        quit_action.triggered.connect(self._quit)
        menu.addAction(quit_action)

        self.tray_icon.setContextMenu(menu)

    def _populate_model_menu(self, models: List[str]):
        """Populates the Model selection submenu with available Ollama models on the GUI thread."""
        self.model_menu.clear()
        self.model_actions_group = QActionGroup(self.model_menu)
        self.model_actions_group.setExclusive(True)

        current_model = OllamaService.shared().model_name

        if not models:
            placeholder = QAction("Scanning models...", self.model_menu)
            placeholder.setEnabled(False)
            self.model_menu.addAction(placeholder)
            return

        for m_name in models:
            action = QAction(m_name, self.model_menu)
            action.setCheckable(True)
            if m_name == current_model:
                action.setChecked(True)

            action.triggered.connect(lambda checked, name=m_name: self._on_model_selected(name))
            self.model_actions_group.addAction(action)
            self.model_menu.addAction(action)

        self.model_menu.addSeparator()
        refresh_action = QAction("🔄 Refresh Models", self.model_menu)
        refresh_action.triggered.connect(self.check_ollama)
        self.model_menu.addAction(refresh_action)

    def _on_model_selected(self, model_name: str):
        """User switched the active translation model from System Tray."""
        st_log(f"TrayApp: User selected model '{model_name}'")
        OllamaService.shared().set_model(model_name)
        self.translation_window.set_model_name(model_name)
        self.config["model"] = model_name
        save_config(self.config)
        self.ollama_action.setText(f"Ollama: {model_name} ✓ Online")

    def on_model_changed_external(self, model_name: str):
        """Called when model is switched inside the HUD to keep System Tray in sync."""
        self.config["model"] = model_name
        self.ollama_action.setText(f"Ollama: {model_name} ✓ Online")
        if self.model_actions_group:
            for action in self.model_actions_group.actions():
                if action.text() == model_name:
                    action.setChecked(True)
                    break

    def on_paused_state_changed(self, is_paused: bool):
        self.selection_monitor.is_enabled = not is_paused
        self.active_action.setChecked(not is_paused)
        self.active_action.setText("Resume ST Hover Translation" if is_paused else "Pause ST Hover Translation")

    def _toggle_active(self, checked: bool):
        self.selection_monitor.is_enabled = checked
        self.active_action.setText("Pause ST Hover Translation" if checked else "Resume ST Hover Translation")
        if hasattr(self, 'translation_window') and self.translation_window:
            self.translation_window.set_paused_state(not checked)
        try:
            import urllib.request
            req = urllib.request.Request("http://127.0.0.1:11436/st-status-updated")
            urllib.request.urlopen(req, timeout=0.5)
        except Exception:
            pass
        st_log(f"toggle_active: is_enabled is now {checked}")

    def _set_hover_delay(self, delay: float):
        self.selection_monitor.hover_delay = delay
        self.config["hover_delay"] = delay
        save_config(self.config)
        st_log(f"set_hover_delay: Hover delay set to {int(delay * 1000)} ms")

    def check_ollama(self):
        self.ollama_action.setText("Ollama: Checking...")
        # Dispatch result safely to GUI thread via signal
        OllamaService.shared().fetch_llm_models(lambda models: self.models_fetched.emit(models))

    def _handle_models_fetched(self, valid_models: List[str]):
        current_model = OllamaService.shared().model_name
        if valid_models:
            self._populate_model_menu(valid_models)
            if current_model in valid_models:
                self.ollama_action.setText(f"Ollama: {current_model} ✓ Online")
            else:
                self.ollama_action.setText(f"Ollama: Online ({len(valid_models)} models)")
        else:
            self.ollama_action.setText("Ollama: ✗ Offline")
            self._populate_model_menu([])

    def _free_vram(self):
        st_log("TrayApp: Free VRAM requested from tray menu")
        def on_done(success: bool, msg: str):
            if success:
                st_log("TrayApp: VRAM successfully freed")
                self.tray_icon.showMessage("ST Translator", "VRAM Freed! LLM unloaded from GPU memory.", QSystemTrayIcon.MessageIcon.Information, 2000)
            else:
                st_log(f"TrayApp: VRAM free error: {msg}")
        OllamaService.shared().free_vram(on_done)

    def _test_popup(self):
        st_log("TrayApp: Test popup triggered")
        sample_text = (
            "Quantum entanglement is a physical phenomenon that occurs when "
            "a group of particles are generated, interact, or share spatial proximity."
        )
        self.translation_window.show_center(sample_text)

    def _quit(self):
        st_log("TrayApp: User selected Quit ST")
        self.selection_monitor.stop()
        self.translation_window.dismiss()
        self.app.quit()
