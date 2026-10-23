import sys
import unittest
from PyQt6.QtWidgets import QApplication
from st_windows.translation_window import TranslationWindow
from st_windows.selection_monitor import SelectionMonitor
from st_windows.tray_app import TrayApp

class TestSTGUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance()
        if not cls.app:
            cls.app = QApplication(sys.argv)

    def test_window_creation(self):
        window = TranslationWindow()
        self.assertEqual(window.is_pinned, False)
        self.assertIn("gemma4:e4b", window.model_btn.text())
        self.assertTrue(window.text_box.isReadOnly())

    def test_selection_monitor(self):
        monitor = SelectionMonitor()
        self.assertTrue(monitor.is_enabled)
        self.assertEqual(monitor.hover_delay, 0.35)
        monitor.start()
        self.assertIsNotNone(monitor._mouse_listener)
        monitor.stop()
        self.assertIsNone(monitor._mouse_listener)

    def test_tray_app(self):
        window = TranslationWindow()
        monitor = SelectionMonitor()
        tray = TrayApp(self.app, monitor, window)
        self.assertIsNotNone(tray.tray_icon)

if __name__ == "__main__":
    unittest.main()
