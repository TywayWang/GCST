import sys
import unittest
from st_windows.logger import st_log
from st_windows.text_extractor import TextExtractor
from st_windows.ollama_service import OllamaService

class TestSTWindows(unittest.TestCase):
    def test_translatable_text(self):
        self.assertTrue(TextExtractor.is_translatable_text("Hello world"))
        self.assertTrue(TextExtractor.is_translatable_text("Quantum entanglement"))
        self.assertTrue(TextExtractor.is_translatable_text("你好世界"))
        self.assertTrue(TextExtractor.is_translatable_text("Freier und Sklave"))
        self.assertFalse(TextExtractor.is_translatable_text("a"))
        self.assertFalse(TextExtractor.is_translatable_text("       "))
        self.assertFalse(TextExtractor.is_translatable_text("123456"))
        self.assertFalse(TextExtractor.is_translatable_text("...---..."))

    def test_clean_extracted_text(self):
        raw = '"Quantum entanglement is physical."\nExcerpt From: Physics Book'
        cleaned = TextExtractor.clean_extracted_text(raw)
        self.assertEqual(cleaned, "Quantum entanglement is physical.")

        raw2 = "“Hello world”\r\n—— 摘自 某书"
        cleaned2 = TextExtractor.clean_extracted_text(raw2)
        self.assertEqual(cleaned2, "Hello world")

    def test_ollama_service(self):
        service = OllamaService.shared()
        self.assertEqual(service.model_name, "gemma4:e4b")

if __name__ == "__main__":
    unittest.main()
