import sys
from datetime import datetime
import inspect
import os

def st_log(message: str):
    """Timestamped diagnostic logger mirroring macOS STLog."""
    now = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    caller = inspect.currentframe().f_back
    filename = os.path.basename(caller.f_code.co_filename) if caller else "unknown"
    lineno = caller.f_lineno if caller else 0
    formatted = f"[ST-Win] [{now}] [{filename}:{lineno}] {message}"
    try:
        print(formatted, flush=True)
    except Exception:
        pass
