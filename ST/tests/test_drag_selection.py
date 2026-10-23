import time
import unittest
from PyQt6.QtWidgets import QApplication
from pynput.mouse import Button
from st_windows.selection_monitor import SelectionMonitor

class TestDragSelection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_drag_selection_detection_and_hover(self):
        monitor = SelectionMonitor(hover_delay=0.05, move_dismiss_radius=100.0)
        events = []
        monitor.translation_requested.connect(lambda: events.append("trans"))

        # 1. Mouse down at (100, 100)
        monitor._on_click(100, 100, Button.left, True)

        # 2. Dragging along to (250, 120)
        monitor._on_move(180, 110)
        monitor._on_move(250, 120)

        # 3. Mouse up at (250, 120)
        monitor._on_click(250, 120, Button.left, False)

        # Bounding box should enclose (100, 100) to (250, 120) with padding
        self.assertIsNotNone(monitor._active_selection_rect)
        min_x, min_y, max_x, max_y = monitor._active_selection_rect
        self.assertLessEqual(min_x, 100)
        self.assertGreaterEqual(max_x, 250)

        # 4. Wait for hover timeout
        time.sleep(0.08)
        self.app.processEvents()

        self.assertEqual(len(events), 1)

    def test_drag_selection_hover_inside_selection_rect(self):
        monitor = SelectionMonitor(hover_delay=0.05, move_dismiss_radius=100.0)
        events = []
        monitor.translation_requested.connect(lambda: events.append("trans"))

        # User drags from (100, 100) to (600, 400) - multi-line paragraph
        monitor._on_click(100, 100, Button.left, True)
        monitor._on_click(600, 400, Button.left, False)

        # User moves cursor back to middle of selection: (300, 250)
        # Distance from (600, 400) to (300, 250) is ~335px (> max_hover_radius 80px),
        # but it is INSIDE active_selection_rect!
        monitor._on_move(300, 250)

        time.sleep(0.08)
        self.app.processEvents()

        # Should still satisfy hover and trigger translation!
        self.assertEqual(len(events), 1)

    def test_short_drag_selection(self):
        monitor = SelectionMonitor(hover_delay=0.05)
        events = []
        monitor.translation_requested.connect(lambda: events.append("trans"))

        # 8px drag (short word / character selection)
        monitor._on_click(100, 100, Button.left, True)
        monitor._on_click(108, 100, Button.left, False)

        time.sleep(0.08)
        self.app.processEvents()

        self.assertEqual(len(events), 1)

if __name__ == "__main__":
    unittest.main()
