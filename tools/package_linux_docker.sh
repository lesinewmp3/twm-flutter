#!/usr/bin/env bash
# Builds dist/TWM-Flutter-x86_64.AppImage in an Ubuntu 22.04 container, so it runs on Ubuntu 22.04 and
# newer (built on a newer system the binary needs its newer GLib, e.g. g_once_init_enter_pointer).
# Builds the current commit (clean clone; uncommitted changes are not included) with the local
# Flutter SDK and pub cache, mounted at the same paths and used as the current user.
# Needs docker, flutter and appimagetool (on PATH or in $FLUTTER / $APPIMAGETOOL).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_bin="$(readlink -f "$(command -v "${FLUTTER:-flutter}")")"
flutter_root="$(dirname "$(dirname "$flutter_bin")")"
pub="${PUB_CACHE:-$HOME/.pub-cache}"
tool="$(readlink -f "${APPIMAGETOOL:-$(command -v appimagetool)}")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"
git clone -q "$root" "$work/src"
# (host network: also works behind VPNs with a smaller MTU than docker's bridge)
docker build --network host -q -t twm-build:22.04 -f "$root/tools/ubuntu22.Dockerfile" "$root/tools" >/dev/null
docker run --rm --network host --user "$(id -u):$(id -g)" \
  -e HOME="$work/home" -e PUB_CACHE="$pub" -e APPIMAGE_EXTRACT_AND_RUN=1 \
  -e FLUTTER="$flutter_root/bin/flutter" -e APPIMAGETOOL="$tool" \
  -v "$flutter_root:$flutter_root" -v "$pub:$pub" -v "$work:$work" -v "$(dirname "$tool"):$(dirname "$tool"):ro" \
  -w "$work/src" twm-build:22.04 tools/package_linux.sh
mkdir -p "$root/dist"
out="$root/dist/TWM-Flutter-x86_64.AppImage"
cp "$work/src/dist/TWM-Flutter-x86_64.AppImage" "$out.part"
mv -f "$out.part" "$out"
echo "-> $out (built on Ubuntu 22.04)"
