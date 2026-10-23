import json
import os
from typing import Any, Dict
from .logger import st_log

CONFIG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.json")

DEFAULT_CONFIG: Dict[str, Any] = {
    "model": "gemma4:e4b",
    "hover_delay": 0.35,
    "move_dismiss_radius": 100.0,
    "source_mode": "Auto",
    "source_lang": "English",
    "target_mode": "Manual",
    "target_lang": "Chinese",
}

def load_config() -> Dict[str, Any]:
    """Loads saved settings or returns default configuration."""
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    cfg.update(data)
        except Exception as e:
            st_log(f"Notice loading config.json: {e}")
    return cfg

def save_config(cfg: Dict[str, Any]):
    """Persists configuration settings to config.json."""
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        st_log(f"Saved configuration to {CONFIG_PATH}")
    except Exception as e:
        st_log(f"Error saving config.json: {e}")
