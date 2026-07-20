"""Hardware-free launcher for the DHT exporter's production app.

The production app (``dht_exporter/rootfs/src/app.py``) imports the Raspberry Pi
libraries ``board`` and ``adafruit_dht`` and reads a real sensor. Those only work
on Pi hardware, so they cannot run in CI.

Instead of maintaining a separate copy of the app, this launcher injects fake
``board`` and ``adafruit_dht`` modules into ``sys.modules`` and then imports the
REAL ``app.py``. This exercises the actual production code paths (metrics
endpoint, temperature scaling, error handling, Prometheus output); only the
hardware leaf is faked.

Run with:
    python -m uvicorn run_app:app --app-dir tests/dht_exporter
"""

import os
import sys
import types

# ---- Fake "board": any D<pin> attribute resolves to a placeholder value. ----
_board = types.ModuleType("board")


def _board_getattr(name: str) -> str:
    # app.py does getattr(board, f"D{PIN}"); return a harmless placeholder.
    return f"PLACEHOLDER_{name}"


_board.__getattr__ = _board_getattr  # type: ignore[attr-defined]
sys.modules["board"] = _board


# ---- Fake "adafruit_dht": DHT11/DHT22 return fixed, valid readings. ----
_adafruit_dht = types.ModuleType("adafruit_dht")


class _FakeDHT:
    def __init__(self, pin, use_pulseio: bool = False) -> None:
        self._pin = pin

    @property
    def temperature(self) -> float:
        return 25.0

    @property
    def humidity(self) -> float:
        return 50.0


_adafruit_dht.DHT11 = _FakeDHT  # type: ignore[attr-defined]
_adafruit_dht.DHT22 = _FakeDHT  # type: ignore[attr-defined]
sys.modules["adafruit_dht"] = _adafruit_dht


# ---- Make the production source importable and import the real app. ----
_SRC_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "dht_exporter", "rootfs", "src")
)
sys.path.insert(0, _SRC_DIR)

from app import app  # noqa: E402  (real production app.py, imported after stubbing)

__all__ = ["app"]
