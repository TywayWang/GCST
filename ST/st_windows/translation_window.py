import sys
import time
import ctypes
from ctypes import c_int, byref
from typing import Optional, List

from PyQt6.QtCore import Qt, QPoint, QRectF, pyqtSignal, QTimer
from PyQt6.QtGui import (
    QFont, QCursor, QGuiApplication, QKeyEvent,
    QPainter, QColor, QPen, QBrush, QAction, QActionGroup
)
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QTextEdit, QFrame, QApplication, QMenu
)

import win32gui
import win32con

from .logger import st_log
from .ollama_service import OllamaService
from .config import load_config, save_config

# Windows DWM constants for Windows 11 rounded corners
DWMWA_WINDOW_CORNER_PREFERENCE = 33
DWMWCP_ROUND = 2

SUPPORTED_LANGUAGES: List[str] = [
    "English",
    "Chinese",
    "French",
    "German",
    "Japanese",
    "Korean",
    "Russian",
]

def detect_language(text: str) -> str:
    """Fast, lightweight language detection for major supported languages."""
    cyrillic = sum(1 for ch in text if 0x0400 <= ord(ch) <= 0x04FF)
    if cyrillic >= 2:
        return "Russian"

    hangul = sum(1 for ch in text if 0xAC00 <= ord(ch) <= 0xD7AF)
    if hangul >= 2:
        return "Korean"

    japanese = sum(1 for ch in text if (0x3040 <= ord(ch) <= 0x30FF))
    if japanese >= 2:
        return "Japanese"

    hanzi = sum(1 for ch in text if 0x4E00 <= ord(ch) <= 0x9FFF)
    if hanzi >= 2:
        return "Chinese"

    lower = text.lower()
    german_markers = ["ä", "ö", "ü", "ß", " und ", " der ", " die ", " das ", " ist ", " nicht "]
    if any(m in lower for m in german_markers):
        return "German"

    french_markers = ["é", "è", "ê", "à", "ç", "œ", "ù", " et ", " le ", " la ", " les ", " est ", " dans "]
    if any(m in lower for m in french_markers):
        return "French"

    return "English"


class DraggableTextEdit(QTextEdit):
    """QTextEdit that supports native mouse-wheel scrolling while forwarding left-click drags to move the parent window."""
    def __init__(self, parent_window: "TranslationWindow"):
        super().__init__()
        self.parent_window = parent_window
        self._drag_pos: Optional[QPoint] = None

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._drag_pos = event.globalPosition().toPoint() - self.parent_window.frameGeometry().topLeft()
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._drag_pos and (event.buttons() & Qt.MouseButton.LeftButton):
            self.parent_window.move(event.globalPosition().toPoint() - self._drag_pos)
            event.accept()
        else:
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        self._drag_pos = None
        event.accept()


class TranslationWindow(QWidget):
    """Minimalist non-activating floating HUD window positioned directly above selected text.
    Full multilingual support (Auto/Manual source & target, swap, model selector, mouse-wheel scrolling).
    """
    token_received = pyqtSignal(str)
    translation_completed = pyqtSignal(str)
    translation_failed = pyqtSignal(str)
    model_changed = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self.is_pinned: bool = False
        self.is_menu_open: bool = False
        self._start_time: float = 0.0
        self._original_text: str = ""
        self._translated_text: str = ""
        self._panel_width: int = 415
        self._panel_height: int = 185
        self._drag_pos: Optional[QPoint] = None

        # Load persisted multi-language settings
        cfg = load_config()
        self.source_mode: str = cfg.get("source_mode", "Auto")
        self.source_lang: str = cfg.get("source_lang", "English")
        self.target_mode: str = cfg.get("target_mode", "Manual")
        self.target_lang: str = cfg.get("target_lang", "Chinese")

        self.token_received.connect(self._handle_token)
        self.translation_completed.connect(self._handle_complete)
        self.translation_failed.connect(self._handle_error)

        # Esc polling timer without installing system-wide keyboard hooks
        self._esc_timer = QTimer(self)
        self._esc_timer.setInterval(40)
        self._esc_timer.timeout.connect(self._check_esc_pressed)

        self._init_ui()
        self._apply_win32_styles()

    def _init_ui(self):
        self.setFixedSize(self._panel_width, self._panel_height)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
        self.setWindowFlags(
            Qt.WindowType.ToolTip |
            Qt.WindowType.FramelessWindowHint |
            Qt.WindowType.WindowStaysOnTopHint |
            Qt.WindowType.WindowDoesNotAcceptFocus
        )

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 8, 14, 9)
        layout.setSpacing(5)

        # 1. Header with Source controls, Swap arrow, Target controls, Model selector, and Latency
        header_layout = QHBoxLayout()
        header_layout.setContentsMargins(0, 0, 0, 0)
        header_layout.setSpacing(5)

        # --- A & B: Source Language Column (Auto/Manual on top, Language name on bottom) ---
        src_col = QVBoxLayout()
        src_col.setContentsMargins(0, 0, 0, 0)
        src_col.setSpacing(1)

        self.src_mode_btn = QPushButton(f"{self.source_mode} ▾")
        self.src_mode_btn.setFont(QFont("Segoe UI", 7, QFont.Weight.Medium))
        self.src_mode_btn.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.src_mode_btn.setStyleSheet(self._mode_btn_style())
        self.src_mode_btn.clicked.connect(self._open_src_mode_menu)
        src_col.addWidget(self.src_mode_btn)

        self.src_lang_btn = QPushButton(f"{self.source_lang} ▾")
        self.src_lang_btn.setFont(QFont("Segoe UI", 8, QFont.Weight.Medium))
        self.src_lang_btn.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.src_lang_btn.setStyleSheet(self._lang_btn_style())
        self.src_lang_btn.clicked.connect(self._open_src_lang_menu)
        src_col.addWidget(self.src_lang_btn)

        header_layout.addLayout(src_col)

        # --- D: Double-headed Arrow (Swap Source & Target) ---
        self.swap_btn = QPushButton("⇄")
        self.swap_btn.setFont(QFont("Segoe UI", 10, QFont.Weight.Bold))
        self.swap_btn.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.swap_btn.setToolTip("Swap Source & Target Languages")
        self.swap_btn.setStyleSheet("""
            QPushButton {
                color: #64748b;
                background: transparent;
                border: none;
                padding: 4px 4px;
                border-radius: 4px;
            }
            QPushButton:hover {
                color: #f1f5f9;
                background: rgba(255, 255, 255, 0.08);
            }
        """)
        self.swap_btn.clicked.connect(self._swap_languages)
        header_layout.addWidget(self.swap_btn)

        # --- E: Target Language Column (Auto/Manual on top, Language name on bottom) ---
        tgt_col = QVBoxLayout()
        tgt_col.setContentsMargins(0, 0, 0, 0)
        tgt_col.setSpacing(1)

        self.tgt_mode_btn = QPushButton(f"{self.target_mode} ▾")
        self.tgt_mode_btn.setFont(QFont("Segoe UI", 7, QFont.Weight.Medium))
        self.tgt_mode_btn.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.tgt_mode_btn.setStyleSheet(self._mode_btn_style())
        self.tgt_mode_btn.clicked.connect(self._open_tgt_mode_menu)
        tgt_col.addWidget(self.tgt_mode_btn)

        self.tgt_lang_btn = QPushButton(f"{self.target_lang} ▾")
        self.tgt_lang_btn.setFont(QFont("Segoe UI", 8, QFont.Weight.Medium))
        self.tgt_lang_btn.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.tgt_lang_btn.setStyleSheet(self._lang_btn_style())
        self.tgt_lang_btn.clicked.connect(self._open_tgt_lang_menu)
        tgt_col.addWidget(self.tgt_lang_btn)

        header_layout.addLayout(tgt_col)

        header_layout.addStretch()

        # --- Model Selector Button ---
        current_model = OllamaService.shared().model_name
        self.model_btn = QPushButton(f"{current_model} ▾")
        self.model_btn.setFont(QFont("Consolas", 8, QFont.Weight.Medium))
        self.model_btn.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.model_btn.setStyleSheet("""
            QPushButton {
                color: #64748b;
                background: transparent;
                border: none;
                padding: 2px 4px;
                border-radius: 4px;
                text-align: right;
            }
            QPushButton:hover {
                color: #f1f5f9;
                background: rgba(255, 255, 255, 0.08);
            }
        """)
        self.model_btn.clicked.connect(self._open_model_menu)
        header_layout.addWidget(self.model_btn)

        # --- Latency Label ---
        self.latency_label = QLabel("")
        self.latency_label.setFont(QFont("Segoe UI", 8))
        self.latency_label.setStyleSheet("color: #475569; background: transparent; border: none;")
        self.latency_label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        header_layout.addWidget(self.latency_label)

        layout.addLayout(header_layout)

        # Subtle divider line
        divider = QFrame()
        divider.setFrameShape(QFrame.Shape.HLine)
        divider.setStyleSheet("background-color: rgba(255, 255, 255, 0.08); max-height: 1px; border: none;")
        divider.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        layout.addWidget(divider)

        # 2. Translated Text Box (Draggable by left-click, scrollable by mouse wheel)
        self.text_box = DraggableTextEdit(self)
        self.text_box.setReadOnly(True)
        self.text_box.setFont(QFont("Microsoft YaHei UI", 10))
        self.text_box.setStyleSheet("""
            QTextEdit {
                background: transparent;
                border: none;
                color: #f8fafc;
                line-height: 1.55;
            }
            QScrollBar:vertical {
                width: 5px;
                background: transparent;
                margin: 0px;
            }
            QScrollBar::handle:vertical {
                background: rgba(255, 255, 255, 0.25);
                border-radius: 2px;
                min-height: 20px;
            }
            QScrollBar::handle:vertical:hover {
                background: rgba(255, 255, 255, 0.45);
            }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
                height: 0px;
            }
            QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
                background: transparent;
            }
        """)
        layout.addWidget(self.text_box)

    def _mode_btn_style(self) -> str:
        return """
            QPushButton {
                color: #64748b;
                background: transparent;
                border: none;
                padding: 1px 3px;
                border-radius: 3px;
                text-align: left;
            }
            QPushButton:hover {
                color: #94a3b8;
                background: rgba(255, 255, 255, 0.06);
            }
        """

    def _lang_btn_style(self) -> str:
        return """
            QPushButton {
                color: #cbd5e1;
                background: transparent;
                border: none;
                padding: 1px 3px;
                border-radius: 3px;
                text-align: left;
            }
            QPushButton:hover {
                color: #ffffff;
                background: rgba(255, 255, 255, 0.08);
            }
        """

    def _create_menu(self) -> QMenu:
        menu = QMenu(self)
        menu.setStyleSheet("""
            QMenu {
                background-color: #1e1e24;
                color: #f1f5f9;
                border: 1px solid #334155;
                border-radius: 6px;
                padding: 4px;
            }
            QMenu::item {
                padding: 5px 22px 5px 12px;
                border-radius: 4px;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                font-size: 8.5pt;
            }
            QMenu::item:selected {
                background-color: #3b82f6;
                color: #ffffff;
            }
        """)
        return menu

    # MARK: - Source & Target Dropdowns

    def _open_src_mode_menu(self):
        self.is_menu_open = True
        menu = self._create_menu()
        for mode in ["Auto", "Manual"]:
            act = QAction(f"Auto Detect" if mode == "Auto" else "Manual Selection", menu)
            act.setCheckable(True)
            act.setChecked(self.source_mode == mode)
            act.triggered.connect(lambda checked, m=mode: self._set_source_mode(m))
            menu.addAction(act)
        pos = self.src_mode_btn.mapToGlobal(QPoint(0, self.src_mode_btn.height() + 2))
        menu.exec(pos)
        self.is_menu_open = False

    def _set_source_mode(self, mode: str):
        self.source_mode = mode
        self.src_mode_btn.setText(f"{mode} ▾")
        self._persist_languages()
        if self._original_text:
            self.show_translation(self._original_text)

    def _open_src_lang_menu(self):
        self.is_menu_open = True
        menu = self._create_menu()
        group = QActionGroup(menu)
        group.setExclusive(True)
        for lang in SUPPORTED_LANGUAGES:
            act = QAction(lang, menu)
            act.setCheckable(True)
            act.setChecked(self.source_lang == lang)
            act.triggered.connect(lambda checked, l=lang: self._set_source_lang(l))
            group.addAction(act)
            menu.addAction(act)
        pos = self.src_lang_btn.mapToGlobal(QPoint(0, self.src_lang_btn.height() + 2))
        menu.exec(pos)
        self.is_menu_open = False

    def _set_source_lang(self, lang: str):
        self.source_lang = lang
        self.source_mode = "Manual"
        self.src_mode_btn.setText("Manual ▾")
        self.src_lang_btn.setText(f"{lang} ▾")
        self._persist_languages()
        if self._original_text:
            self.show_translation(self._original_text)

    def _open_tgt_mode_menu(self):
        self.is_menu_open = True
        menu = self._create_menu()
        for mode in ["Auto", "Manual"]:
            act = QAction(f"Auto Detect" if mode == "Auto" else "Manual Selection", menu)
            act.setCheckable(True)
            act.setChecked(self.target_mode == mode)
            act.triggered.connect(lambda checked, m=mode: self._set_target_mode(m))
            menu.addAction(act)
        pos = self.tgt_mode_btn.mapToGlobal(QPoint(0, self.tgt_mode_btn.height() + 2))
        menu.exec(pos)
        self.is_menu_open = False

    def _set_target_mode(self, mode: str):
        self.target_mode = mode
        self.tgt_mode_btn.setText(f"{mode} ▾")
        self._persist_languages()
        if self._original_text:
            self.show_translation(self._original_text)

    def _open_tgt_lang_menu(self):
        self.is_menu_open = True
        menu = self._create_menu()
        group = QActionGroup(menu)
        group.setExclusive(True)
        for lang in SUPPORTED_LANGUAGES:
            act = QAction(lang, menu)
            act.setCheckable(True)
            act.setChecked(self.target_lang == lang)
            act.triggered.connect(lambda checked, l=lang: self._set_target_lang(l))
            group.addAction(act)
            menu.addAction(act)
        pos = self.tgt_lang_btn.mapToGlobal(QPoint(0, self.tgt_lang_btn.height() + 2))
        menu.exec(pos)
        self.is_menu_open = False

    def _set_target_lang(self, lang: str):
        self.target_lang = lang
        self.target_mode = "Manual"
        self.tgt_mode_btn.setText("Manual ▾")
        self.tgt_lang_btn.setText(f"{lang} ▾")
        self._persist_languages()
        if self._original_text:
            self.show_translation(self._original_text)

    def _swap_languages(self):
        """Swaps source and target languages and re-translates."""
        st_log(f"Swapping languages: {self.source_lang} <-> {self.target_lang}")
        self.source_lang, self.target_lang = self.target_lang, self.source_lang
        self.source_mode, self.target_mode = "Manual", "Manual"
        self.src_mode_btn.setText(f"{self.source_mode} ▾")
        self.tgt_mode_btn.setText(f"{self.target_mode} ▾")
        self.src_lang_btn.setText(f"{self.source_lang} ▾")
        self.tgt_lang_btn.setText(f"{self.target_lang} ▾")
        self._persist_languages()
        if self._original_text:
            self.show_translation(self._original_text)

    def _persist_languages(self):
        cfg = load_config()
        cfg["source_mode"] = self.source_mode
        cfg["source_lang"] = self.source_lang
        cfg["target_mode"] = self.target_mode
        cfg["target_lang"] = self.target_lang
        save_config(cfg)

    # MARK: - Model Dropdown

    def _open_model_menu(self):
        self.is_menu_open = True
        menu = self._create_menu()

        models = OllamaService.shared().cached_models
        current = OllamaService.shared().model_name
        if not models:
            models = [current]

        group = QActionGroup(menu)
        group.setExclusive(True)

        for m_name in models:
            action = QAction(m_name, menu)
            action.setCheckable(True)
            if m_name == current:
                action.setChecked(True)
            action.triggered.connect(lambda checked, name=m_name: self._select_model(name))
            group.addAction(action)
            menu.addAction(action)

        btn_pos = self.model_btn.mapToGlobal(QPoint(0, self.model_btn.height() + 2))
        menu.exec(btn_pos)
        self.is_menu_open = False

    def _select_model(self, name: str):
        st_log(f"TranslationWindow: Switched to model '{name}' from dropdown")
        OllamaService.shared().set_model(name)
        self.set_model_name(name)
        cfg = load_config()
        cfg["model"] = name
        save_config(cfg)
        self.model_changed.emit(name)

        if self._original_text:
            self.show_translation(self._original_text)

    def set_model_name(self, name: str):
        self.model_btn.setText(f"{name} ▾")

    def paintEvent(self, event):
        """Paints a solid dark rounded card background with crisp antialiased border."""
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        painter.setBrush(QBrush(QColor("#16171d")))
        painter.setPen(QPen(QColor(255, 255, 255, 36), 1.0))

        rect = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        painter.drawRoundedRect(rect, 10.0, 10.0)

    def _apply_win32_styles(self):
        """Sets WS_EX_NOACTIVATE and DWM rounded corners via Win32 API."""
        try:
            hwnd = int(self.winId())
            ex_style = win32gui.GetWindowLong(hwnd, win32con.GWL_EXSTYLE)
            win32gui.SetWindowLong(
                hwnd,
                win32con.GWL_EXSTYLE,
                ex_style | win32con.WS_EX_NOACTIVATE | win32con.WS_EX_TOPMOST | win32con.WS_EX_TOOLWINDOW
            )

            if hasattr(ctypes.windll, "dwmapi"):
                val = c_int(DWMWCP_ROUND)
                ctypes.windll.dwmapi.DwmSetWindowAttribute(
                    hwnd,
                    DWMWA_WINDOW_CORNER_PREFERENCE,
                    byref(val),
                    ctypes.sizeof(val)
                )
        except Exception as e:
            st_log(f"Notice applying Win32 styles: {e}")

    # MARK: - Window Dragging Anywhere Inside Card

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._drag_pos = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._drag_pos and (event.buttons() & Qt.MouseButton.LeftButton):
            self.move(event.globalPosition().toPoint() - self._drag_pos)
            event.accept()
        else:
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        self._drag_pos = None
        event.accept()

    # MARK: - Show & Translation Pipeline

    def show_translation(self, text: str):
        """Positions HUD relative to current cursor and begins streaming translation."""
        active_model = OllamaService.shared().model_name
        self.set_model_name(active_model)

        self._original_text = text
        self._translated_text = ""
        self.latency_label.setText("")

        # Update source language indicator if auto-detecting
        effective_source_lang = self.source_lang
        if self.source_mode == "Auto":
            detected = detect_language(text)
            effective_source_lang = detected
            self.src_lang_btn.setText(f"{detected} ▾")
            self.src_mode_btn.setText("Auto ▾")
        else:
            self.src_lang_btn.setText(f"{self.source_lang} ▾")
            self.src_mode_btn.setText("Manual ▾")

        self.tgt_mode_btn.setText(f"{self.target_mode} ▾")
        self.tgt_lang_btn.setText(f"{self.target_lang} ▾")

        target_display = "Chinese/English" if self.target_mode == "Auto" else self.target_lang
        self.text_box.setHtml(f"<span style='color: #64748b; font-style: italic;'>Translating ({effective_source_lang} → {target_display}) with {active_model}...</span>")
        self.text_box.verticalScrollBar().setValue(0)

        # Position HUD in Qt logical coordinate space relative to current cursor
        self._position_hud()

        # Show non-activating in Qt
        self.show()
        self.raise_()
        self.update()
        if hasattr(self, '_esc_timer'):
            self._esc_timer.start()
        QApplication.processEvents()

        # Begin Ollama stream with configured language parameters
        self._start_time = time.time()
        service = OllamaService.shared()
        service.translate_stream(
            text=text,
            on_token=lambda tok: self.token_received.emit(tok),
            on_complete=self._on_ollama_complete,
            source_lang=effective_source_lang,
            target_lang=self.target_lang,
            source_mode=self.source_mode,
            target_mode=self.target_mode
        )

    def show_center(self, text: str):
        """Shows HUD in center of primary screen (used for manual test)."""
        screen = QGuiApplication.primaryScreen()
        if screen:
            geo = screen.availableGeometry()
            target_x = geo.center().x() - (self._panel_width // 2)
            target_y = geo.center().y() - (self._panel_height // 2)
            self.move(target_x, target_y)

        self.show_translation(text)

    def _position_hud(self):
        """Calculates popup position in Qt logical points directly above cursor."""
        cursor = QCursor.pos()
        cursor_x = cursor.x()
        cursor_y = cursor.y()

        screen = QGuiApplication.screenAt(cursor)
        if not screen:
            screen = QGuiApplication.primaryScreen()
        if not screen:
            self.move(cursor_x - (self._panel_width // 2), cursor_y - self._panel_height - 16)
            return

        avail = screen.availableGeometry()
        w = self._panel_width
        h = self._panel_height

        target_x = cursor_x - (w // 2)
        target_y = cursor_y - h - 16

        if target_y < avail.top() + 10:
            target_y = cursor_y + 24

        if target_x < avail.left() + 10:
            target_x = avail.left() + 10
        elif target_x + w > avail.right() - 10:
            target_x = avail.right() - w - 10

        if target_y + h > avail.bottom() - 10:
            target_y = avail.bottom() - h - 10
        if target_y < avail.top() + 10:
            target_y = avail.top() + 10

        self.move(target_x, target_y)

    def _handle_token(self, token: str):
        if not self._translated_text:
            self.text_box.clear()
        self._translated_text += token

        # Preserve scrollbar position: keep showing from the beginning naturally
        val = self.text_box.verticalScrollBar().value()
        self.text_box.setPlainText(self._translated_text)
        if val == 0:
            self.text_box.verticalScrollBar().setValue(0)
        else:
            self.text_box.verticalScrollBar().setValue(val)

    def _on_ollama_complete(self, result: Optional[str], err: Optional[Exception]):
        if err:
            self.translation_failed.emit(str(err))
        elif result is not None:
            self.translation_completed.emit(result)

    def _handle_complete(self, final_text: str):
        self._translated_text = final_text
        val = self.text_box.verticalScrollBar().value()
        self.text_box.setPlainText(final_text)
        if val == 0:
            self.text_box.verticalScrollBar().setValue(0)
        else:
            self.text_box.verticalScrollBar().setValue(val)

        elapsed_ms = int((time.time() - self._start_time) * 1000)
        self.latency_label.setText(f"{elapsed_ms} ms")

    def _handle_error(self, err_msg: str):
        if not self._translated_text:
            self.text_box.setHtml(f"<span style='color: #ef4444;'>Error: {err_msg}</span>")

    def _check_esc_pressed(self):
        if not self.isVisible():
            if hasattr(self, '_esc_timer'):
                self._esc_timer.stop()
            return
        try:
            import win32api
            import win32con
            if (win32api.GetAsyncKeyState(win32con.VK_ESCAPE) & 0x8000) != 0:
                self.dismiss()
        except Exception:
            pass

    def dismiss(self):
        if hasattr(self, '_esc_timer'):
            self._esc_timer.stop()
        OllamaService.shared().cancel_current_translation()
        self.hide()

    def hideEvent(self, event):
        if hasattr(self, '_esc_timer'):
            self._esc_timer.stop()
        super().hideEvent(event)

    def is_point_inside(self, x: int = 0, y: int = 0) -> bool:
        """Determines if the mouse cursor is currently within the popup bounds in Qt coordinate space."""
        if not self.isVisible():
            return False
        if self.is_menu_open:
            return True
        cursor = QCursor.pos()
        hit_rect = self.frameGeometry().adjusted(-4, -4, 4, 4)
        return hit_rect.contains(cursor)

    def keyPressEvent(self, event: QKeyEvent):
        if event.key() == Qt.Key.Key_Escape:
            self.dismiss()
        else:
            super().keyPressEvent(event)
