# Dual Scan

A Mac app for the Konica Minolta Dimage Scan Dual IV, to replace VueScan.
Scan once at full quality, make a base edit live (no rescans), then export
a JPEG, a 16-bit base TIFF or the raw scan, or open the scans in another app.

## How it talks to the scanner

No reverse engineering needed: the open-source SANE project added Dual IV
support to its `avision` driver in November 2026. It is not in a SANE release
yet, so it is built from source here:

```
cd sane-backends
PATH="/opt/homebrew/opt/libtool/libexec/gnubin:$PATH" ./autogen.sh
./configure --prefix=$HOME/dualscan/sane BACKENDS="avision test" --with-usb --without-snmp --disable-locking
make -j8 && make install
printf 'avision\ntest\n' > ../sane/etc/sane.d/dll.conf
```

Needs `brew install autoconf autoconf-archive automake libtool pkgconf libusb gettext xcodegen`.

## Building the app

```
app/build.sh            # → app/build/Dual Scan.app
```

## Trying it without the scanner

The app has a simulated Dual IV that produces fake orange negatives:

- on the first screen, click "No scanner here? Use a simulated one", or
- start it with `--simulate`.

`--selftest <folder>` runs the whole flow on the simulator, saves pictures of
the window and the exported files there, and quits.

## Where files go

- Raw scans are kept in `~/Pictures/Dual Scan/<date> <roll>/Raw`.
- Exports go to that roll folder unless you choose another one when exporting.

## Folders

- `app/` — the SwiftUI app (`project.yml` for XcodeGen; `scripts/make-icon.swift` draws the icon)
- `sane-backends/` — SANE source, `sane/` — the built driver
- `reference/` — the driver source and manual, for reading
