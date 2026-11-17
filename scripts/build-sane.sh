#!/bin/bash
# Builds the SANE driver that goes inside Dual Scan.app into ../sane/:
# only the avision backend (Dimage Scan Dual IV), as one static library with the
# backend preloaded, plus a static libusb. The app then needs nothing outside itself.
# Skips the build when ../sane already holds this commit.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# SANE master with Dual IV support in avision (not in a release yet).
SANE_COMMIT=7bf6abe2bd1b1cb916aa87b6a377a7ee70313eb3
SRC="$ROOT/build/sane-src"
OUT="$ROOT/sane"
# Our fixes on top of that commit; the stamp changes whenever a patch does, so it rebuilds.
PATCHES=("$ROOT"/scripts/sane-patches/*.patch)
STAMP="$SANE_COMMIT $(cat "${PATCHES[@]}" | shasum | cut -c1-12)"

if [ "$(cat "$OUT/.commit" 2>/dev/null)" = "$STAMP" ] && [ -f "$OUT/lib/libsane.a" ]; then
  echo "SANE $SANE_COMMIT is already built."
  exit 0
fi

for tool in autoconf automake glibtoolize pkg-config; do
  command -v $tool >/dev/null 2>&1 || {
    echo "$tool is missing. Install with:  brew install autoconf autoconf-archive automake libtool pkgconf libusb gettext"
    exit 1
  }
done
LIBUSB_A="$(brew --prefix libusb)/lib/libusb-1.0.a"
[ -f "$LIBUSB_A" ] || { echo "libusb is missing. Install with:  brew install libusb"; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://gitlab.com/sane-project/backends.git
fi
git -C "$SRC" fetch -q --depth 1 origin "$SANE_COMMIT"
git -C "$SRC" checkout -q --force FETCH_HEAD
git -C "$SRC" clean -qfdx
for p in "${PATCHES[@]}"; do git -C "$SRC" apply "$p"; done

cd "$SRC"
# A shallow checkout has no tags to take the version from.
echo "1.4.0.352-7bf6" > .tarball-version
./autogen.sh >/dev/null
export MACOSX_DEPLOYMENT_TARGET=26.0
# dll-preload.h stores backend functions untyped; new clang makes that an error.
./configure --prefix="$OUT" BACKENDS="avision" CFLAGS="-O2 -arch arm64 -Wno-error=incompatible-function-pointer-types" \
  --disable-shared --enable-static --enable-preload \
  --with-usb --without-snmp --without-avahi --without-libcurl --without-poppler-glib \
  --without-usb-record-replay --without-gphoto2 --without-v4l --without-systemd \
  --without-libjpeg --without-libtiff --without-libpng \
  --disable-locking --disable-nls >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
rm -rf "$OUT"
make install >/dev/null

cp "$LIBUSB_A" "$OUT/lib/libusb-static.a"
chmod u+w "$OUT/lib/libusb-static.a"
# The config the app ships with: only avision, no firmware upload (the Dual IV's own firmware).
printf 'avision\n' > "$OUT/etc/sane.d/dll.conf"
echo "$STAMP" > "$OUT/.commit"
echo "Built SANE $STAMP into sane/"
