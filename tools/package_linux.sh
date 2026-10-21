#!/usr/bin/env bash
# Builds the Linux desktop app and packs it into one file: dist/TWM-Flutter-x86_64.AppImage
# (Flutter bundle + octave/ + data/). Needs appimagetool on PATH or in $APPIMAGETOOL.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
flutter="${FLUTTER:-flutter}"
tool="${APPIMAGETOOL:-appimagetool}"

cd "$root/app"
"$flutter" build linux --release

appdir="$root/build/TWM-Flutter.AppDir"
rm -rf "$appdir"
mkdir -p "$appdir/usr"
cp -a build/linux/x64/release/bundle/. "$appdir/usr/"
cp -a "$root/octave" "$root/data" "$appdir/usr/"
cp web/icons/Icon-512.png "$appdir/twm-flutter.png"
cat > "$appdir/twm-flutter.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=TWM Flutter
Comment=TracePQM wattmeter and PQ analyzer
Exec=twm_app
Icon=twm-flutter
Categories=Science;Engineering;
DESK
cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
exec "$here/usr/twm_app" "$@"
RUN
chmod +x "$appdir/AppRun"

mkdir -p "$root/dist"
# build next to the target and replace it: works while the old AppImage runs
out="$root/dist/TWM-Flutter-x86_64.AppImage"
ARCH=x86_64 "$tool" --no-appstream "$appdir" "$out.part"
mv -f "$out.part" "$out"
echo "-> $out"
