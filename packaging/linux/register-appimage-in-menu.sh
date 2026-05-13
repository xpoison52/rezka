#!/usr/bin/env bash
# Регистрирует rezka-native *.AppImage в меню пользователя (GNOME/KDE/XFCE и т.д., Freedesktop).
# Сам файл в ~/AppImages меню не «видит», пока нет .desktop в ~/.local/share/applications.
#
# Использование:
#   chmod +x ~/AppImages/rezka-native-1.2.3-aarch64.AppImage
#   ./packaging/linux/register-appimage-in-menu.sh ~/AppImages/rezka-native-1.2.3-aarch64.AppImage
#
set -eu

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Использование: $0 /полный/путь/к/rezka-native-версия-арх.AppImage" >&2
  exit 1
fi

RAW="$1"
APPIMAGE="$(readlink -f "$RAW")"
if [[ ! -f "$APPIMAGE" ]]; then
  echo "Файл не найден: $RAW" >&2
  exit 1
fi
chmod +x "$APPIMAGE" || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ICON_SRC="$ROOT/packaging/linux/icons/rezka-native.svg"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
ICONS_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
mkdir -p "$APPS_DIR" "$ICONS_DIR"

if [[ -f "$ICON_SRC" ]]; then
  install -Dm644 "$ICON_SRC" "$ICONS_DIR/rezka-native.svg"
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true
  fi
  ICON_LINE="Icon=rezka-native"
else
  # без иконки из репозитория — подставим путь к SVG из AppDir нельзя без распаковки
  ICON_LINE="Icon=multimedia-video-player"
fi

DESKTOP="$APPS_DIR/rezka-native-appimage.desktop"
# Exec и TryExec в кавычках: путь может содержать пробелы.
{
  echo "[Desktop Entry]"
  echo "Type=Application"
  echo "Name=Rezka Native"
  echo "Comment=Клиент Rezka (AppImage)"
  echo "Exec=\"$APPIMAGE\" %U"
  echo "TryExec=$APPIMAGE"
  echo "$ICON_LINE"
  echo "Categories=AudioVideo;Video;Network;"
  echo "Terminal=false"
  echo "StartupNotify=true"
  echo "StartupWMClass=rezka-native"
} >"$DESKTOP"

chmod 644 "$DESKTOP"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" 2>/dev/null || true
fi

echo "Запись меню: $DESKTOP"
echo "Приложение: $APPIMAGE"
echo "Если ярлык не появился сразу — выйдите из сессии или перезапустите оболочку (на Pi иногда нужен ребут панели)."
