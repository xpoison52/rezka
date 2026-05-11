# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec: Linux (and other platforms) one-file GUI bundle.
from pathlib import Path

from PyInstaller.utils.hooks import collect_all

project_root = Path(SPEC).parent.resolve()

block_cipher = None

extra_datas = [
    (str(project_root / "main.qml"), "."),
]
_av = project_root / "app-version.txt"
if _av.exists():
    extra_datas.append((str(_av), "."))

pds_datas, pds_binaries, pds_hiddenimports = collect_all("PySide6")

a = Analysis(
    [str(project_root / "main.py")],
    pathex=[str(project_root)],
    binaries=pds_binaries,
    datas=extra_datas + pds_datas,
    hiddenimports=pds_hiddenimports
    + [
        "HdRezkaApi",
        "HdRezkaApi.types",
        "bs4",
        "requests",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="rezka-native",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
