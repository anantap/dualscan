# Dual Scan

A Mac app for the Konica Minolta Dimage Scan Dual IV, to replace VueScan.
Scan once at full quality, make a base edit live (no rescans), then export
a JPEG, a 16-bit base TIFF or the raw scan, or open the scans in another app.

## How it talks to the scanner

No reverse engineering needed: the open-source SANE project added Dual IV
support to its `avision` driver in November 2026. It is not in a SANE release
yet, so `scripts/build-sane.sh` builds it from a pinned master commit into
`sane/`: only the avision backend, as one static library, with a static libusb.
Both are linked into the app, so `Dual Scan.app` needs nothing outside itself.

Needs `brew install autoconf autoconf-archive automake libtool pkgconf libusb gettext xcodegen`.

## Building the app

```
app/build.sh            # → app/build/Dual Scan.app (builds SANE first if needed)
app/build.sh --install  # … and copies it to /Applications
```

## Updates

Like Roll Converter: every push to `main` that touches the app makes GitHub
(`.github/workflows/mac-app.yml`) build it, run the self-test and publish it
as the latest release, `build-<n>` with `Dual-Scan.zip`. The app looks for a
newer build when it starts (and under Dual Scan › Check for Updates…),
downloads it in the background and puts it in place when you restart or quit.
It won't restart while the scanner or an export is busy. A local build is
build 1 and never looks for updates.

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
