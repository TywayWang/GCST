import math
import time
import threading
from typing import Callable, Optional
from PyQt6.QtCore import QObject, pyqtSignal
from pynput import mouse
from .logger import st_log

class SelectionMonitor(QObject):
    translation_requested = pyqtSignal()
    dismiss_requested = pyqtSignal()

    def __init__(self, hover_delay: float = 0.35, move_dismiss_radius: float = 100.0):
        super().__init__()
        self.is_enabled: bool = True
        self.hover_delay: float = hover_delay
        self.max_hover_radius: float = 80.0
        self.move_dismiss_radius: float = move_dismiss_radius

        self.is_panel_visible: Callable[[], bool] = lambda: False
        self.is_panel_pinned: Callable[[], bool] = lambda: False
        self.is_point_inside_panel: Callable[[int, int], bool] = lambda x, y: False

        # State tracking
        self._mouse_listener: Optional[mouse.Listener] = None

        self._mouse_down_pos: tuple[int, int] = (0, 0)
        self._mouse_down_time: float = 0.0
        self._last_click_time: float = 0.0
        self._last_click_pos: tuple[int, int] = (0, 0)
        self._click_count: int = 0

        self._hover_timer: Optional[threading.Timer] = None
        self._pending_selection_pos: tuple[int, int] = (0, 0)
        self._active_selection_rect: Optional[tuple[float, float, float, float]] = None
        self._translation_origin: tuple[int, int] = (0, 0)
        self._cursor_entered_panel: bool = False
        self._lock = threading.Lock()

    def start(self):
        """Starts global mouse listener."""
        self.stop()
        st_log("SelectionMonitor: Starting mouse listener...")

        self._mouse_listener = mouse.Listener(
            on_click=self._on_click,
            on_move=self._on_move
        )
        self._mouse_listener.daemon = True
        self._mouse_listener.start()
        st_log("SelectionMonitor: Listeners active.")

    def start_esc_listener(self):
        """No-op: Esc dismiss is handled safely by TranslationWindow polling timer without system keyboard hooks."""
        pass

    def stop_esc_listener(self):
        """No-op: Esc dismiss is handled safely by TranslationWindow polling timer without system keyboard hooks."""
        pass

    def stop(self):
        """Stops listeners and cancels any active timers."""
        with self._lock:
            if self._hover_timer:
                self._hover_timer.cancel()
                self._hover_timer = None

        if self._mouse_listener:
            try:
                self._mouse_listener.stop()
            except Exception:
                pass
            self._mouse_listener = None

    def _on_click(self, x: int, y: int, button, pressed: bool):
        if button != mouse.Button.left:
            return

        now = time.time()

        if pressed:
            # Mouse button pressed down
            with self._lock:
                if self._hover_timer:
                    self._hover_timer.cancel()
                    self._hover_timer = None

            self._mouse_down_pos = (x, y)
            self._mouse_down_time = now

            # Outside click detection (ALWAYS active so panel can be dismissed):
            if self.is_panel_visible():
                if not self.is_point_inside_panel(x, y):
                    st_log("SelectionMonitor: Outside click detected -> requesting dismiss")
                    self.dismiss_requested.emit()

            # Multi-click detection (double/triple click word selection)
            dist_to_last_click = math.hypot(x - self._last_click_pos[0], y - self._last_click_pos[1])
            if (now - self._last_click_time < 0.40) and (dist_to_last_click < 15):
                self._click_count += 1
            else:
                self._click_count = 1

            self._last_click_time = now
            self._last_click_pos = (x, y)

        else:
            # Mouse button released (Up): only trigger hover check if translation is enabled
            if not self.is_enabled:
                return

            drag_dist = math.hypot(x - self._mouse_down_pos[0], y - self._mouse_down_pos[1])

            # Selection gesture: drag distance >= 6.0px (matching macOS wasDrag > 6.0) or double/triple click
            is_selection = (drag_dist >= 6.0) or (self._click_count >= 2)

            if is_selection:
                p1 = self._mouse_down_pos
                p2 = (x, y)
                min_x = min(p1[0], p2[0]) - 50.0
                max_x = max(p1[0], p2[0]) + 50.0
                min_y = min(p1[1], p2[1]) - 40.0
                max_y = max(p1[1], p2[1]) + 40.0
                self._active_selection_rect = (min_x, min_y, max_x, max_y)

                st_log(f"SelectionMonitor: Selection gesture detected (drag_dist={drag_dist:.1f}px, click_count={self._click_count}, rect=({min_x:.0f},{min_y:.0f},{max_x:.0f},{max_y:.0f})). Starting {int(self.hover_delay*1000)}ms hover timer...")
                self._pending_selection_pos = (x, y)
                self._schedule_hover_check(x, y)

    def _schedule_hover_check(self, origin_x: int, origin_y: int):
        with self._lock:
            if self._hover_timer:
                self._hover_timer.cancel()

            def on_hover_timeout():
                curr_x, curr_y = self._pending_selection_pos
                dist = math.hypot(curr_x - origin_x, curr_y - origin_y)

                is_inside_selection = False
                if self._active_selection_rect is not None:
                    min_x, min_y, max_x, max_y = self._active_selection_rect
                    is_inside_selection = (min_x <= curr_x <= max_x) and (min_y <= curr_y <= max_y)

                # Mirror macOS ST: satisfied if cursor is inside selection rect OR within max_hover_radius
                if is_inside_selection or (dist <= self.max_hover_radius):
                    st_log(f"SelectionMonitor: Hover satisfied (dist={dist:.1f}px <= {self.max_hover_radius}px, insideSelection={is_inside_selection}). Requesting translation.")
                    self._translation_origin = (curr_x, curr_y)
                    self._cursor_entered_panel = False
                    self.translation_requested.emit()
                else:
                    st_log(f"SelectionMonitor: Hover aborted (moved {dist:.1f}px > {self.max_hover_radius}px and outside selection rect)")

            timer = threading.Timer(self.hover_delay, on_hover_timeout)
            timer.daemon = True
            self._hover_timer = timer
            timer.start()

    def _on_move(self, x: int, y: int):
        if not self.is_enabled:
            return

        self._pending_selection_pos = (x, y)

        # Automatic close when cursor moves:
        if self.is_panel_visible():
            inside = self.is_point_inside_panel(x, y)
            if inside:
                # User moved cursor inside the HUD (e.g. to drag it)
                self._cursor_entered_panel = True
            else:
                if self._cursor_entered_panel:
                    # Cursor was inside the HUD and just moved out
                    st_log("SelectionMonitor: Cursor moved outside panel -> auto-dismissing")
                    self.dismiss_requested.emit()
                else:
                    # Cursor was at the selection point where hover occurred
                    orig_x, orig_y = self._translation_origin
                    dist = math.hypot(x - orig_x, y - orig_y)
                    if dist > self.move_dismiss_radius:
                        st_log(f"SelectionMonitor: Cursor moved away ({dist:.1f}px > {self.move_dismiss_radius:.0f}px) -> auto-dismissing")
                        self.dismiss_requested.emit()
