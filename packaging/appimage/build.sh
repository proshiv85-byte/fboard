#!/bin/sh
# Builds fboard-x86_64.AppImage from a release bundle using linuxdeploy
# (bundles FFmpeg and friends so it runs on any distro).
# usage: packaging/appimage/build.sh <bundle dir> <version>
set -eu
BUNDLE=$(realpath "$1"); VERSION=$2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d); APPDIR=$WORK/AppDir
"$ROOT/packaging/install.sh" "$BUNDLE" "$APPDIR" /usr
rm -rf "$APPDIR/usr/lib/udev" "$APPDIR/usr/bin"
cd "$WORK"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
chmod +x linuxdeploy-x86_64.AppImage
# The Flutter binary must stay next to its data/ and lib/ folders, so only its
# dependencies are deployed; AppRun starts it. Flutter's libraries are found here:
export LD_LIBRARY_PATH="$APPDIR/usr/lib/fboard/lib:${LD_LIBRARY_PATH:-}"
export APPIMAGE_EXTRACT_AND_RUN=1 VERSION
./linuxdeploy-x86_64.AppImage --appdir "$APPDIR" \
  --deploy-deps-only "$APPDIR/usr/lib/fboard/fboard" \
  --deploy-deps-only "$APPDIR/usr/lib/fboard/lib" \
  --desktop-file "$APPDIR/usr/share/applications/io.github.proshiv85_byte.fboard.desktop" \
  --icon-file "$ROOT/data/icons/io.github.proshiv85_byte.fboard.svg" \
  --custom-apprun "$ROOT/packaging/appimage/AppRun" \
  --output appimage
mv fboard*.AppImage "$ROOT/fboard-$VERSION-x86_64.AppImage"
