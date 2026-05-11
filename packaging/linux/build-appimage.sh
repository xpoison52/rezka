#!/usr/bin/env bash
# Сборка AppImage из уже собранного PyInstaller one-file бинарника dist/rezka-native.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BIN="$ROOT/dist/rezka-native"
if [[ ! -f "$BIN" || ! -x "$BIN" ]]; then
  echo "Нет исполняемого $BIN — сначала: pyinstaller rezka-native.spec"
  exit 1
fi

DESKTOP="$ROOT/packaging/linux/rezka-native.desktop"
ICON_SVG="$ROOT/packaging/linux/icons/rezka-native.svg"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ICON_PNG="$WORKDIR/rezka-native.png"
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 256 -h 256 "$ICON_SVG" -o "$ICON_PNG"
else
  echo "Установите rsvg-convert (librsvg2-bin) для PNG-иконки, или положите rezka-native.png рядом со скриптом."
  exit 1
fi

LINUXDEPLOY="$WORKDIR/linuxdeploy-x86_64.AppImage"
wget -q -O "$LINUXDEPLOY" "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
chmod +x "$LINUXDEPLOY"

APPDIR="$WORKDIR/AppDir"
mkdir -p "$APPDIR" "$ROOT/dist"
VERSION="${REZKA_VERSION:-0.0.0}"
export VERSION
OUT="$ROOT/dist/rezka-native-${VERSION}-x86_64.AppImage"

# linuxdeploy требует --appdir; сборку ведём из WORKDIR (там же появится *.AppImage)
cd "$WORKDIR"
"$LINUXDEPLOY" --appimage-extract-and-run \
  --appdir "$APPDIR" \
  --executable "$BIN" \
  --desktop-file "$DESKTOP" \
  --icon-file "$ICON_PNG" \
  --output appimage

# Не брать скачанный linuxdeploy-*.AppImage
shopt -s nullglob
mapfile -t imgs < <(find "$WORKDIR" -maxdepth 1 -name "*.AppImage" ! -name "linuxdeploy*.AppImage" -print)
if [[ ${#imgs[@]} -eq 0 ]]; then
  echo "AppImage не найден после linuxdeploy"
  ls -la "$WORKDIR" "$APPDIR" 2>/dev/null || true
  exit 1
fi
BUILT="$(ls -t "${imgs[@]}" | head -1)"
mv -f "$BUILT" "$OUT"
echo "Готово: $OUT"
