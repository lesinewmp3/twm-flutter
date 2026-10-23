#!/usr/bin/env bash
# Builds the Linux desktop app and packs it into one file: dist/TWM-Flutter-x86_64.AppImage
# (Flutter bundle + octave/ + data/ + portable GNU Octave). Needs appimagetool on PATH or in $APPIMAGETOOL
# and the portable Octave from tools/bundle_octave.sh in $OCTAVE_RUNTIME (default build/octave-runtime;
# OCTAVE_RUNTIME=none packs without it: the PC then needs its own Octave).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
flutter="${FLUTTER:-flutter}"
tool="${APPIMAGETOOL:-appimagetool}"
octave_rt="${OCTAVE_RUNTIME:-$root/build/octave-runtime}"
if [ "$octave_rt" != none ] && [ ! -x "$octave_rt/bin/octave-cli" ]; then
  echo "No portable Octave in $octave_rt: run tools/bundle_octave.sh (or OCTAVE_RUNTIME=none)" >&2
  exit 1
fi

cd "$root/app"
"$flutter" build linux --release

appdir="$root/build/TWM-Flutter.AppDir"
rm -rf "$appdir"
mkdir -p "$appdir/usr"
cp -a build/linux/x64/release/bundle/. "$appdir/usr/"
cp -a "$root/octave" "$root/data" "$appdir/usr/"
[ "$octave_rt" = none ] || cp -a "$octave_rt" "$appdir/octave-runtime"
cp web/icons/Icon-512.png "$appdir/twm-flutter.png"
cat > "$appdir/twm-flutter.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=TWM Flutter
Comment=TracePQM wattmeter and PQ analyzer
Exec=twm_app
Icon=twm-flutter
StartupWMClass=cz.tracepqm.twm_app
Categories=Science;Engineering;
DESK
cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
# the bundled Octave is found first (the app starts octave-cli from PATH unless a path is configured)
[ -x "$here/octave-runtime/bin/octave-cli" ] && export PATH="$here/octave-runtime/bin:$PATH"
exec "$here/usr/twm_app" "$@"
RUN
chmod +x "$appdir/AppRun"

mkdir -p "$root/dist"
# build next to the target and replace it: works while the old AppImage runs
out="$root/dist/TWM-Flutter-x86_64.AppImage"
ARCH=x86_64 "$tool" --no-appstream "$appdir" "$out.part"
mv -f "$out.part" "$out"
echo "-> $out"
