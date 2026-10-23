import json
import threading
from typing import Callable, List, Optional
import requests
from .logger import st_log

class OllamaService:
    _instance: Optional["OllamaService"] = None

    @classmethod
    def shared(cls) -> "OllamaService":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def __init__(self, host: str = "http://127.0.0.1:11434", model_name: str = "gemma4:e4b"):
        self.host = host
        self.model_name = model_name
        self.cached_models: List[str] = []
        self._current_cancel_event = threading.Event()
        self._active_thread: Optional[threading.Thread] = None

    def set_model(self, model: str):
        """Switches the active translation model."""
        self.model_name = model
        st_log(f"OllamaService: Model switched to '{model}'")

    def check_health(self, completion: Callable[[bool, List[str]], None]):
        """Asynchronously checks Ollama status and returns all installed model names."""
        def worker():
            try:
                resp = requests.get(f"{self.host}/api/tags", timeout=3.0)
                if resp.status_code == 200:
                    data = resp.json()
                    models = [m.get("name", "") for m in data.get("models", []) if m.get("name")]
                    completion(True, models)
                    return
            except Exception as e:
                st_log(f"Ollama health check failed: {e}")
            completion(False, [])

        threading.Thread(target=worker, daemon=True).start()

    def fetch_llm_models(self, completion: Optional[Callable[[List[str]], None]] = None):
        """Fetches locally deployed models suitable for text translation (filtering out pure embedding models)."""
        def worker():
            try:
                resp = requests.get(f"{self.host}/api/tags", timeout=3.0)
                if resp.status_code == 200:
                    data = resp.json()
                    valid_models = []
                    for m in data.get("models", []):
                        name = m.get("name", "")
                        caps = m.get("capabilities", [])
                        if "embedding" in caps and "completion" not in caps:
                            continue
                        if "embedding" in name.lower():
                            continue
                        if name:
                            valid_models.append(name)
                    self.cached_models = valid_models
                    if completion:
                        completion(valid_models)
                    return
            except Exception as e:
                st_log(f"fetch_llm_models failed: {e}")
            if completion:
                completion(self.cached_models)

        threading.Thread(target=worker, daemon=True).start()

    def cancel_current_translation(self):
        """Cancels any in-flight translation request."""
        self._current_cancel_event.set()

    def translate_stream(
        self,
        text: str,
        on_token: Callable[[str], None],
        on_complete: Callable[[Optional[str], Optional[Exception]], None],
        source_lang: str = "Auto",
        target_lang: str = "Chinese",
        source_mode: str = "Auto",
        target_mode: str = "Manual"
    ):
        """Streams translation token-by-token from Ollama supporting arbitrary source and target languages."""
        self.cancel_current_translation()

        cancel_event = threading.Event()
        self._current_cancel_event = cancel_event

        def worker():
            st_log(f"translate_stream: [{source_mode}:{source_lang} -> {target_mode}:{target_lang}] using '{self.model_name}' (len {len(text)})...")

            if source_mode == "Auto" and target_mode == "Auto":
                system_prompt = (
                    "You are a professional multilingual translator. Automatically detect the source language. "
                    "If the input is in Chinese, translate it into fluent, natural English. "
                    "If the input is in English or any other language, translate it into fluent, natural Simplified Chinese. "
                    "Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
                )
            elif source_mode == "Auto":
                system_prompt = (
                    f"You are a professional multilingual translator. Automatically detect the source language of the input "
                    f"and translate it into fluent, natural {target_lang}. "
                    f"Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
                )
            elif target_mode == "Auto":
                system_prompt = (
                    f"You are a professional multilingual translator. Translate the {source_lang} user input into "
                    f"fluent, natural Simplified Chinese (or into English if the input is Chinese). "
                    f"Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
                )
            else:
                system_prompt = (
                    f"You are a professional multilingual translator. Translate the following {source_lang} user input "
                    f"into fluent, natural {target_lang}. "
                    f"Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
                )

            payload = {
                "model": self.model_name,
                "system": system_prompt,
                "prompt": text,
                "stream": True,
                "options": {
                    "temperature": 0.2
                }
            }

            accumulated = []
            try:
                with requests.post(
                    f"{self.host}/api/generate",
                    json=payload,
                    stream=True,
                    timeout=30.0
                ) as resp:
                    if resp.status_code != 200:
                        raise RuntimeError(f"Ollama returned HTTP {resp.status_code}: {resp.text}")

                    for line in resp.iter_lines():
                        if cancel_event.is_set():
                            st_log("translate_stream: Cancelled during stream")
                            return

                        if not line:
                            continue

                        try:
                            chunk = json.loads(line)
                            token = chunk.get("response", "")
                            if token:
                                accumulated.append(token)
                                on_token(token)

                            if chunk.get("done", False):
                                final_result = "".join(accumulated).strip()
                                st_log(f"translate_stream: Completed ({len(final_result)} chars)")
                                on_complete(final_result, None)
                                return
                        except json.JSONDecodeError:
                            continue

                if not cancel_event.is_set():
                    final_result = "".join(accumulated).strip()
                    on_complete(final_result, None)

            except Exception as e:
                if not cancel_event.is_set():
                    st_log(f"translate_stream error: {e}")
                    on_complete(None, e)

        thread = threading.Thread(target=worker, daemon=True)
        self._active_thread = thread
        thread.start()
