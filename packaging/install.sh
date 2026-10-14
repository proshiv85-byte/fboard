#!/bin/sh
# Installs a built bundle into a prefix.
# usage: packaging/install.sh <bundle dir> <destdir> [prefix=/usr]
set -eu
BUNDLE=$1; DEST=$2; PREFIX=${3:-/usr}
APPID=io.github.proshiv85_byte.fboard
ROOT=$(cd "$(dirname "$0")/.." && pwd)
install -d "$DEST$PREFIX/lib/fboard" "$DEST$PREFIX/bin"
cp -a "$BUNDLE"/. "$DEST$PREFIX/lib/fboard/"
ln -sf "$PREFIX/lib/fboard/fboard" "$DEST$PREFIX/bin/fboard"
# Flutter plugin libraries carry runpaths into the build tree; point them at
# the bundle instead (rpm rejects the originals).
if command -v patchelf >/dev/null; then
  for f in "$DEST$PREFIX"/lib/fboard/lib/*.so; do
    [ -n "$(patchelf --print-rpath "$f" 2>/dev/null)" ] && patchelf --set-rpath '$ORIGIN' "$f"
  done
fi
install -Dm644 "$ROOT/data/$APPID.desktop" "$DEST$PREFIX/share/applications/$APPID.desktop"
install -Dm644 "$ROOT/data/$APPID.metainfo.xml" "$DEST$PREFIX/share/metainfo/$APPID.metainfo.xml"
install -Dm644 "$ROOT/data/icons/$APPID.svg" "$DEST$PREFIX/share/icons/hicolor/scalable/apps/$APPID.svg"
install -Dm644 "$ROOT/data/70-fboard.rules" "$DEST$PREFIX/lib/udev/rules.d/70-fboard.rules"
install -Dm644 "$ROOT/LICENSE" "$DEST$PREFIX/share/licenses/fboard/LICENSE"
