#!/usr/bin/env bash
# Builds a portable GNU Octave for the AppImage: build/octave-runtime/ (bin/octave-cli + usr/ + lib/).
# Octave 8.4 and the packages io, signal, statistics, optim (+ control, struct) with OpenBLAS are taken
# from Ubuntu 24.04 - the versions the validation was run with. The runtime brings its own glibc and
# dynamic loader, so it runs on older and other distributions too, and it ignores an Octave installed
# on the PC (packages, ~/.octaverc). Needs docker.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/octave-runtime"
rm -rf "$out"
mkdir -p "$out"
# (host network: also works behind VPNs with a smaller MTU than docker's bridge)
docker run --rm --network host -e DEBIAN_FRONTEND=noninteractive -v "$out:/out" ubuntu:24.04 bash -euo pipefail -c '
apt-get update -qq
apt-get install -y -qq --no-install-recommends octave octave-io octave-signal octave-statistics octave-optim \
  libopenblas0-pthread >/dev/null
o=/out
mkdir -p $o/bin $o/lib $o/usr/bin $o/usr/lib/x86_64-linux-gnu $o/usr/share
cp -L /usr/bin/octave-cli $o/usr/bin/octave-cli
cp -a /usr/share/octave $o/usr/share/
cp -a /usr/lib/x86_64-linux-gnu/octave $o/usr/lib/x86_64-linux-gnu/
rm -rf $o/usr/share/octave/*/doc
# graphics toolkits are not used (no plots in Octave windows) and need GL/FLTK/Qt
rm -f $o/usr/lib/x86_64-linux-gnu/octave/*/oct/*/__init_fltk__.oct $o/usr/lib/x86_64-linux-gnu/octave/*/liboctgui.so*
sed -i "/fltk/d" $o/usr/lib/x86_64-linux-gnu/octave/*/oct/*/PKG_ADD
# shared libraries: closure of octave-cli and all .oct/.so files (dereferenced alternatives, e.g. OpenBLAS)
find $o/usr -type f \( -name "*.oct" -o -name "*.so*" -o -path "*/bin/*" \) > /tmp/objs
while read -r f; do ldd "$f" 2>/dev/null; done < /tmp/objs | awk "/=> \\//{print \$3}" | sort -u > /tmp/libs
while read -r l; do cp -L "$l" $o/lib/; done < /tmp/libs
# liboctave/liboctinterp are now in lib/ (searched before the RUNPATH of octave-cli)
rm -f $o/usr/lib/x86_64-linux-gnu/octave/*/liboct*.so*
cp -L /lib64/ld-linux-x86-64.so.2 $o/lib/
cp -a /usr/lib/x86_64-linux-gnu/gconv $o/lib/
if grep -q "not found" <(while read -r f; do ldd "$f" 2>/dev/null; done < /tmp/objs); then
  echo "missing libraries:" >&2
  while read -r f; do ldd "$f" 2>/dev/null | grep "not found" | sed "s|^|$f: |"; done < /tmp/objs >&2
  exit 1
fi
# packages: the list holds absolute paths; the startup file rewrites it for the place the runtime runs from
cp /usr/share/octave/octave_packages $o/usr/share/octave/octave_packages.dist
rm -f $o/usr/share/octave/octave_packages
mkdir -p $o/usr/share/octave/site/m/startup
rm -f $o/usr/share/octave/site/m/startup/octaverc
cat > $o/usr/share/octave/site/m/startup/octaverc <<"RC"
## TWM-Flutter portable Octave: packages of this runtime only, not those of an installed Octave
pkg("local_list", fullfile(tempdir(), sprintf("twm-octave-local-%d", getpid())));
load(fullfile(OCTAVE_HOME, "share", "octave", "octave_packages.dist"), "global_packages");
for k = 1:numel(global_packages)
  global_packages{k}.dir = strrep(global_packages{k}.dir, "/usr/", [OCTAVE_HOME "/"]);
  global_packages{k}.archprefix = strrep(global_packages{k}.archprefix, "/usr/", [OCTAVE_HOME "/"]);
end
twm_pkg_list = fullfile(tempdir(), sprintf("twm-octave-packages-%d", getpid()));
save("-text", twm_pkg_list, "global_packages");
pkg("global_list", twm_pkg_list);
clear global_packages k twm_pkg_list
RC
dpkg-query -W -f="\${Package} \${Version}\n" octave octave-io octave-signal octave-statistics octave-optim \
  octave-control octave-struct libopenblas0-pthread > $o/VERSIONS
chown -R '"$(id -u):$(id -g)"' $o
'
cat > "$out/bin/octave-cli" <<'SH'
#!/bin/sh
# Portable GNU Octave of TWM-Flutter: runs octave-cli with the bundled glibc and libraries.
# The environment of the PC (LD_LIBRARY_PATH, ~/.octaverc) is not used.
d="$(dirname "$(dirname "$(readlink -f "$0")")")"
export OCTAVE_HOME="$d/usr" GCONV_PATH="$d/lib/gconv" LC_ALL=C.UTF-8
unset LD_LIBRARY_PATH LD_PRELOAD OCTAVE_PATH
exec "$d/lib/ld-linux-x86-64.so.2" --library-path "$d/lib" --argv0 octave-cli "$d/usr/bin/octave-cli" --no-init-file "$@"
SH
chmod +x "$out/bin/octave-cli"
echo "-> $out ($(du -sh "$out" | cut -f1))"
cat "$out/VERSIONS"
