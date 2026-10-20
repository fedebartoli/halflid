#!/bin/bash
# Builds the file to publish: build/dist/HalfLid-<version>.zip and its SHA-256 checksum.
#
#   scripts/package.sh                    version 0.1.0, arm64 and x86_64
#   VERSION=0.2.0 scripts/package.sh
#   ARCHS=arm64 scripts/package.sh        this Mac's architecture only
#
# The app is signed ad hoc, not with an Apple Developer ID, and it is not notarized. A downloaded copy therefore carries the
# quarantine flag and macOS asks for confirmation the first time (README, "Install"). Nothing here uploads anything.
set -euo pipefail
cd "$(dirname "$0")/.."

export VERSION="${VERSION:-0.1.0}"
export ARCHS="${ARCHS:-arm64 x86_64}"
DIST="build/dist"
ZIP="$DIST/HalfLid-$VERSION.zip"

scripts/make-app.sh

# Every executable must hold every architecture asked for, or a user of the missing one gets a broken app.
for FILE in build/HalfLid.app/Contents/MacOS/* "build/HalfLid.app/Contents/Helpers/Half Lid Settings.app/Contents/MacOS/"*; do
  for ARCH in $ARCHS; do
    lipo "$FILE" -verify_arch "$ARCH" || { echo "error: $FILE has no $ARCH slice" >&2; exit 1; }
  done
done

rm -rf "$DIST"
mkdir -p "$DIST"
# ditto keeps what a plain zip loses (extended attributes, symbolic links) and is what Finder's "Compress" uses.
ditto -c -k --keepParent build/HalfLid.app "$ZIP"
(cd "$DIST" && shasum -a 256 "HalfLid-$VERSION.zip" > "HalfLid-$VERSION.zip.sha256")

echo "Built $ZIP ($(du -k "$ZIP" | cut -f1) KB, architectures: $ARCHS)"
cat "$ZIP.sha256"
