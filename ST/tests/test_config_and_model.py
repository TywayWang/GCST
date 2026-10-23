import os
import unittest
from st_windows.config import load_config, save_config, CONFIG_PATH
from st_windows.ollama_service import OllamaService
from st_windows.selection_monitor import SelectionMonitor

class TestConfigAndModel(unittest.TestCase):
    def test_selection_monitor_radius(self):
        mon = SelectionMonitor(move_dismiss_radius=100.0)
        self.assertEqual(mon.move_dismiss_radius, 100.0)

    def test_model_switching(self):
        service = OllamaService.shared()
        orig = service.model_name
        service.set_model("translator:latest")
        self.assertEqual(service.model_name, "translator:latest")
        service.set_model(orig)

    def test_config_save_load(self):
        cfg = load_config()
        cfg["model"] = "qwen3:8b"
        cfg["move_dismiss_radius"] = 100.0
        save_config(cfg)

        loaded = load_config()
        self.assertEqual(loaded["model"], "qwen3:8b")
        self.assertEqual(loaded["move_dismiss_radius"], 100.0)

        # Restore default
        cfg["model"] = "gemma4:e4b"
        save_config(cfg)

if __name__ == "__main__":
    unittest.main()
