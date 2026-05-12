# SPDX-License-Identifier: MIT
"""huyauncher-hotkeys.json + /dev/input/js* → синтетические QKeyEvent (Linux, Steam Deck)."""

from __future__ import annotations

import json
import os
import stat
import struct
import sys
import time
from pathlib import Path
from typing import Any, Callable

_JS_FMT = "@IhBB"  # time, value, type, number — 8 байт (linux/joystick.h)
_JS_BUTTON = 0x01
_JS_INIT = 0x80

_ACTION_TO_QT: dict[str, int] = {}
_TV_ACTION_KEYS = ("left", "right", "up", "down", "back", "confirm")


def _init_qt_keys() -> None:
    global _ACTION_TO_QT
    if _ACTION_TO_QT:
        return
    from PySide6.QtCore import Qt

    _ACTION_TO_QT = {
        "right": int(Qt.Key.Key_Right),
        "left": int(Qt.Key.Key_Left),
        "up": int(Qt.Key.Key_Up),
        "down": int(Qt.Key.Key_Down),
        "confirm": int(Qt.Key.Key_Return),
        "back": int(Qt.Key.Key_Escape),
    }


def _action_to_qt_with_tv_file(data_root: Path, log: Callable[[str], None]) -> dict[str, int]:
    _init_qt_keys()
    merged = dict(_ACTION_TO_QT)
    p = data_root / "tv-hotkeys.json"
    if not p.is_file():
        return merged
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        log(f"huyauncher: tv-hotkeys.json не прочитан {p}: {e}")
        return merged
    if not isinstance(raw, dict):
        return merged
    for act in _TV_ACTION_KEYS:
        v = raw.get(act)
        if isinstance(v, bool) or v is None:
            continue
        try:
            iv = int(v)
        except (TypeError, ValueError):
            continue
        if iv > 0:
            merged[str(act)] = iv
    log(f"huyauncher: Qt-коды из {p} (для js-моста)")
    return merged


def _candidate_hotkey_files(data_root: Path, app_root: Path) -> list[Path]:
    seen: set[str] = set()
    out: list[Path] = []

    def add(p: Path) -> None:
        k = str(p)
        if k not in seen:
            seen.add(k)
            out.append(p)

    env = (os.environ.get("HUYLAUNCHER_HOTKEYS") or "").strip()
    if env:
        add(Path(env))
    add(Path.home() / ".local" / "share" / "rezka-native" / "huyauncher-hotkeys.json")
    add(data_root / "huyauncher-hotkeys.json")
    add(app_root / "huyauncher-hotkeys.json")
    return out


def _merge_button_to_qt(
    paths: list[Path], action_to_qt: dict[str, int], log: Callable[[str], None]
) -> dict[int, int]:
    _init_qt_keys()
    merged: dict[int, int] = {}
    for p in paths:
        if not p.is_file():
            continue
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            log(f"huyauncher: не прочитан {p}: {e}")
            continue
        if not isinstance(raw, dict):
            continue
        file_map: dict[int, int] = {}
        for action, spec in raw.items():
            if not isinstance(spec, dict) or spec.get("kind") != "button":
                continue
            act = str(action)
            qk = action_to_qt.get(act)
            if qk is None:
                continue
            try:
                btn = int(spec.get("js_button", spec.get("index", -1)))
            except (TypeError, ValueError):
                continue
            if btn < 0:
                continue
            file_map[btn] = int(qk)
        if file_map:
            log(f"huyauncher: привязки из {p} ({len(file_map)} кн.)")
        merged.update(file_map)
    return merged


class HuyLauncherJoyBridge:
    def __init__(
        self,
        qapp: Any,
        windows: list[Any],
        data_root: Path,
        app_root: Path,
        log: Callable[[str], None],
    ) -> None:
        from PySide6.QtCore import QEvent, QObject, QSocketNotifier, Qt, QTimer
        from PySide6.QtGui import QGuiApplication, QKeyEvent
        from PySide6.QtQuick import QQuickWindow

        self._log = log
        self._qapp: QGuiApplication = qapp
        self._windows = [w for w in windows if isinstance(w, QQuickWindow)]
        self._paths = _candidate_hotkey_files(data_root, app_root)
        self._data_root = data_root
        self._action_to_qt = _action_to_qt_with_tv_file(data_root, log)
        self._btn_to_qt = _merge_button_to_qt(self._paths, self._action_to_qt, log)
        self._fd: int | None = None
        self._notifier: QObject | None = None
        self._reload_timer: QTimer | None = None
        self._last_fire: dict[int, float] = {}
        self._QEvent = QEvent
        self._Qt = Qt
        self._QKeyEvent = QKeyEvent

        if not self._btn_to_qt:
            log("huyauncher: нет huyauncher-hotkeys.json или пустой — мост js не активен")
            return

        fd = self._open_first_js()
        if fd is None:
            log("huyauncher: нет доступного /dev/input/js* — геймпад только через Qt/Steam")
            return

        self._fd = fd
        self._notifier = QSocketNotifier(fd, QSocketNotifier.Type.Read, qapp)
        self._notifier.activated.connect(self._on_js_ready)

        self._reload_timer = QTimer(qapp)
        self._reload_timer.setInterval(2000)
        self._reload_timer.timeout.connect(self._maybe_reload)
        self._reload_timer.start()

        self._mtime = self._max_mtime()
        log(f"huyauncher: мост /dev/input/js* активен (кнопок в карте: {len(self._btn_to_qt)})")

    def _max_mtime(self) -> float:
        t = 0.0
        for p in self._paths:
            try:
                t = max(t, p.stat().st_mtime)
            except OSError:
                pass
        tv = self._data_root / "tv-hotkeys.json"
        try:
            t = max(t, tv.stat().st_mtime)
        except OSError:
            pass
        return t

    def _maybe_reload(self) -> None:
        mt = self._max_mtime()
        if mt > self._mtime:
            self._mtime = mt
            self._action_to_qt = _action_to_qt_with_tv_file(self._data_root, self._log)
            self._btn_to_qt = _merge_button_to_qt(self._paths, self._action_to_qt, self._log)

    def _open_first_js(self) -> int | None:
        devdir = Path("/dev/input")
        if not devdir.is_dir():
            return None
        names: list[str] = []
        for p in devdir.glob("js*"):
            try:
                st = p.lstat()
            except OSError:
                continue
            if not stat.S_ISCHR(st.st_mode):
                continue
            names.append(p.name)
        for name in sorted(names):
            p = devdir / name
            try:
                return os.open(str(p), os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
        return None

    def _on_js_ready(self) -> None:
        if self._fd is None:
            return
        from PySide6.QtGui import QGuiApplication

        size = struct.calcsize(_JS_FMT)
        while True:
            try:
                buf = os.read(self._fd, size)
            except BlockingIOError:
                break
            except OSError as e:
                self._log(f"huyauncher: read js: {e}")
                break
            if len(buf) < size:
                break
            _js_time, value, typ, number = struct.unpack(_JS_FMT, buf[:size])
            if typ & _JS_INIT:
                continue
            base = typ & 0x7F
            if base != _JS_BUTTON or not value:
                continue
            now = time.monotonic()
            if self._last_fire.get(number, 0) + 0.12 > now:
                continue
            self._last_fire[number] = now
            qk = self._btn_to_qt.get(int(number))
            if qk is None:
                continue
            win = self._qapp.focusWindow()
            if win is None and self._windows:
                win = self._windows[0]
            if win is None:
                continue
            ev = self._QKeyEvent(
                self._QEvent.Type.KeyPress,
                self._Qt.Key(int(qk)),
                self._Qt.KeyboardModifier.NoModifier,
            )
            QGuiApplication.sendEvent(win, ev)

    def close(self) -> None:
        if self._reload_timer is not None:
            self._reload_timer.stop()
            self._reload_timer.deleteLater()
            self._reload_timer = None
        if self._notifier is not None:
            self._notifier.setEnabled(False)
            self._notifier.deleteLater()
            self._notifier = None
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None


def install_if_enabled(
    qapp: Any,
    windows: list[Any],
    data_root: Path,
    app_root: Path,
    log: Callable[[str], None],
) -> HuyLauncherJoyBridge | None:
    if sys.platform != "linux":
        return None
    if os.environ.get("HUYLAUNCHER_DISABLE", "").strip() == "1":
        log("huyauncher: отключено (HUYLAUNCHER_DISABLE=1)")
        return None
    bridge = HuyLauncherJoyBridge(qapp, windows, data_root, app_root, log)
    if bridge._notifier is None:
        return None
    qapp.aboutToQuit.connect(bridge.close)
    return bridge
