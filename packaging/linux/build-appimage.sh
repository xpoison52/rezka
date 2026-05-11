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

mkdir -p "$ROOT/dist"
VERSION="${REZKA_VERSION:-0.0.0}"
export VERSION
OUT="$ROOT/dist/rezka-native-${VERSION}-x86_64.AppImage"

"$LINUXDEPLOY" --appimage-extract-and-run \
  --executable "$BIN" \
  --desktop-file "$DESKTOP" \
  --icon-file "$ICON_PNG" \
  --output appimage \
  -v0

# linuxdeploy обычно кладёт *.AppImage в cwd (ROOT); иногда в dist/
shopt -s nullglob
mapfile -t imgs < <(
  {
    find "$ROOT" -maxdepth 1 -name "*.AppImage" -print
    find "$ROOT/dist" -maxdepth 1 -name "*.AppImage" -print 2>/dev/null || true
  } | sort -u
)
if [[ ${#imgs[@]} -eq 0 ]]; then
  echo "AppImage не найден после linuxdeploy"
  find "$ROOT" -maxdepth 3 -type f 2>/dev/null | head -80 || true
  ls -la "$ROOT" "$ROOT/dist" 2>/dev/null || true
  exit 1
fi
# берём самый новый файл
BUILT="$(ls -t "${imgs[@]}" | head -1)"
mv -f "$BUILT" "$OUT"
echo "Готово: $OUT"
