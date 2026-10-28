import re
import time
import threading
from typing import Callable, Optional
import win32api
import win32con
import win32clipboard
from .logger import st_log

try:
    import uiautomation as auto
except ImportError:
    auto = None

class TextExtractor:
    _instance: Optional["TextExtractor"] = None

    @classmethod
    def shared(cls) -> "TextExtractor":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    @staticmethod
    def is_translatable_text(text: str) -> bool:
        """Checks if text contains readable characters across supported languages (Latin, Cyrillic, CJK, etc.) and is suitable for translation."""
        trimmed = text.strip()
        if len(trimmed) < 2:
            return False

        letter_count = sum(1 for ch in trimmed if ch.isalpha())
        return letter_count >= 2

    @staticmethod
    def clean_extracted_text(raw: str) -> str:
        """Cleans up citations, excerpts, and surrounding quotation marks."""
        text = raw.replace("\r\n", "\n").strip()

        # Strip common excerpt / citation footers from PDF readers and browsers
        citation_markers = [
            "\nexcerpt from:",
            "\n—— 摘自",
            "\n-- 摘自",
            "\nsource:"
        ]
        lower_text = text.lower()
        for marker in citation_markers:
            idx = lower_text.find(marker)
            if idx != -1:
                text = text[:idx]
                lower_text = text.lower()

        # Strip surrounding quotes and whitespace
        quote_chars = '“”"\'«»「」『』`'
        text = text.strip().strip(quote_chars).strip()
        return text

    def extract_selected_text(self, completion: Callable[[Optional[str]], None]):
        """Asynchronously extracts selected text using UIAutomation or synthetic Ctrl+C fallback."""
        def worker():
            st_log("extract_selected_text: Beginning extraction...")

            # Strategy 1: UIAutomation TextPattern
            if auto is not None:
                try:
                    focused = auto.GetFocusedControl()
                    if focused:
                        pattern = focused.GetPattern(auto.PatternId.TextPattern)
                        if pattern:
                            ranges = pattern.GetSelection()
                            if ranges:
                                sel_text = "".join(r.GetText(-1) for r in ranges).strip()
                                if sel_text and self.is_translatable_text(sel_text):
                                    clean = self.clean_extracted_text(sel_text)
                                    st_log(f"extract_selected_text: Strategy 1 (UIAutomation) succeeded: '{clean[:40]}'")
                                    completion(clean)
                                    return
                except Exception as e:
                    st_log(f"Strategy 1 (UIAutomation) notice: {e}")

            # Check if foreground window is Windows File Explorer or Desktop (CabinetWClass, Progman, WorkerW)
            # If so, file selection marquee/clicking must NEVER trigger synthetic Ctrl+C fallback!
            try:
                import win32gui
                hwnd = win32gui.GetForegroundWindow()
                cls_name = win32gui.GetClassName(hwnd)
                if cls_name in ("CabinetWClass", "Progman", "WorkerW", "Shell_TrayWnd"):
                    st_log(f"extract_selected_text: Foreground window is '{cls_name}'. Skipping Ctrl+C fallback to avoid capturing selected files.")
                    completion(None)
                    return
            except Exception:
                pass

            # Strategy 2: Synthetic Ctrl+C with Smart Clipboard Restoration
            st_log("extract_selected_text: Strategy 1 yielded no text, falling back to Strategy 2 (Ctrl+C)...")
            copied = self._extract_via_clipboard()
            if copied and self.is_translatable_text(copied):
                clean = self.clean_extracted_text(copied)
                st_log(f"extract_selected_text: Strategy 2 (Ctrl+C) succeeded: '{clean[:40]}'")
                completion(clean)
                return

            st_log("extract_selected_text: All strategies failed to retrieve translatable text")
            completion(None)

        threading.Thread(target=worker, daemon=True).start()

    def _extract_via_clipboard(self) -> Optional[str]:
        """Backs up clipboard, sends Ctrl+C, captures text, and restores original clipboard."""
        backup_text = None
        has_backup = False

        # 1. Backup existing clipboard content
        for _ in range(3):
            try:
                win32clipboard.OpenClipboard()
                if win32clipboard.IsClipboardFormatAvailable(win32con.CF_UNICODETEXT):
                    backup_text = win32clipboard.GetClipboardData(win32con.CF_UNICODETEXT)
                    has_backup = True
                else:
                    has_backup = False
                win32clipboard.CloseClipboard()
                break
            except Exception:
                time.sleep(0.02)
                try:
                    win32clipboard.CloseClipboard()
                except Exception:
                    pass

        # 2. Clear clipboard so we can detect if fresh text was copied
        try:
            win32clipboard.OpenClipboard()
            win32clipboard.EmptyClipboard()
            win32clipboard.CloseClipboard()
        except Exception:
            try:
                win32clipboard.CloseClipboard()
            except Exception:
                pass

        # 3. Brief settling delay and simulate Ctrl+C
        # Wait 35ms to ensure target application finishes rendering selection highlight
        time.sleep(0.035)

        # Release any stuck modifiers and trigger Ctrl+C cleanly
        win32api.keybd_event(win32con.VK_CONTROL, 0, 0, 0)
        win32api.keybd_event(0x43, 0, 0, 0)  # 'C' key
        time.sleep(0.035)
        win32api.keybd_event(0x43, 0, win32con.KEYEVENTF_KEYUP, 0)
        win32api.keybd_event(win32con.VK_CONTROL, 0, win32con.KEYEVENTF_KEYUP, 0)

        # 4. Wait for application to populate clipboard (poll up to 450ms, matching macOS maxMs)
        extracted_text = None
        start_time = time.time()
        while time.time() - start_time < 0.45:
            time.sleep(0.025)
            try:
                win32clipboard.OpenClipboard()
                # Check for file drop format (CF_HDROP = 15) to avoid translating copied file paths
                if win32clipboard.IsClipboardFormatAvailable(15):
                    st_log("extract_selected_text: Clipboard contains file drop payload (CF_HDROP), discarding.")
                    win32clipboard.CloseClipboard()
                    return None

                if win32clipboard.IsClipboardFormatAvailable(win32con.CF_UNICODETEXT):
                    data = win32clipboard.GetClipboardData(win32con.CF_UNICODETEXT)
                    if data and data.strip():
                        extracted_text = data
                win32clipboard.CloseClipboard()
                if extracted_text:
                    break
            except Exception:
                try:
                    win32clipboard.CloseClipboard()
                except Exception:
                    pass

        # 5. Restore original clipboard asynchronously only after extraction completes
        def restore_worker():
            time.sleep(0.35)
            if has_backup and backup_text is not None:
                for _ in range(5):
                    try:
                        win32clipboard.OpenClipboard()
                        win32clipboard.EmptyClipboard()
                        win32clipboard.SetClipboardData(win32con.CF_UNICODETEXT, backup_text)
                        win32clipboard.CloseClipboard()
                        break
                    except Exception:
                        time.sleep(0.05)
                        try:
                            win32clipboard.CloseClipboard()
                        except Exception:
                            pass

        threading.Thread(target=restore_worker, daemon=True).start()

        return extracted_text
