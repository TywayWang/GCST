import unittest
from PyQt6.QtWidgets import QApplication
from st_windows.translation_window import TranslationWindow, detect_language, SUPPORTED_LANGUAGES
from st_windows.config import load_config, save_config

class TestMultilingual(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance()
        if not cls.app:
            cls.app = QApplication([])

    def test_language_detection(self):
        self.assertEqual(detect_language("Quantum mechanics and general relativity"), "English")
        self.assertEqual(detect_language("Freier und Sklave, Patrizier und Plebejer"), "German")
        self.assertEqual(detect_language("Liberté, égalité, fraternité et justice"), "French")
        self.assertEqual(detect_language("Квантовая запутанность"), "Russian")
        self.assertEqual(detect_language("量子もつれは、物理現象である"), "Japanese")
        self.assertEqual(detect_language("양자 얽힘은 물리적 현상이다"), "Korean")
        self.assertEqual(detect_language("量子纠缠是一种物理现象"), "Chinese")

    def test_ui_controls(self):
        orig_cfg = dict(load_config())
        try:
            win = TranslationWindow()
            self.assertTrue(hasattr(win, "src_mode_btn"))
            self.assertTrue(hasattr(win, "src_lang_btn"))
            self.assertTrue(hasattr(win, "swap_btn"))
            self.assertTrue(hasattr(win, "tgt_mode_btn"))
            self.assertTrue(hasattr(win, "tgt_lang_btn"))

            # Test setting source language
            win._set_source_lang("German")
            self.assertEqual(win.source_lang, "German")
            self.assertEqual(win.source_mode, "Manual")

            # Test setting target language
            win._set_target_lang("Japanese")
            self.assertEqual(win.target_lang, "Japanese")

            # Test swap
            win._swap_languages()
            self.assertEqual(win.source_lang, "Japanese")
            self.assertEqual(win.target_lang, "German")
        finally:
            save_config(orig_cfg)

if __name__ == "__main__":
    unittest.main()
