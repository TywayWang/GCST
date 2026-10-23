import unittest
from PyQt6.QtWidgets import QApplication
from st_windows.translation_window import TranslationWindow, DraggableTextEdit

class TestScrollAndSrc(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance()
        if not cls.app:
            cls.app = QApplication([])

    def test_no_src_preview(self):
        win = TranslationWindow()
        self.assertFalse(hasattr(win, "original_preview"))
        self.assertIsInstance(win.text_box, DraggableTextEdit)

    def test_scroll_top_during_stream(self):
        win = TranslationWindow()
        win.show()
        # Stream 40 tokens
        for i in range(40):
            win._handle_token(f"Token {i} representing a long sentence in a translated paragraph.\n")
        self.assertEqual(win.text_box.verticalScrollBar().value(), 0)
        self.assertGreater(win.text_box.verticalScrollBar().maximum(), 0)

if __name__ == "__main__":
    unittest.main()
