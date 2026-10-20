#!/bin/bash
# Builds the library (debug) and runs the test executable. Exit code 0 means every check passed.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug scripts/build.sh >/dev/null
ARCH="$(uname -m)"
SLICE="build/slices/$ARCH"
# shellcheck disable=SC2046
swiftc -swift-version 5 -target "$ARCH-apple-macos14.0" -Onone -g \
  -I "$SLICE/lib" -L "$SLICE/lib" -lHalfLidCore -framework IOKit -framework AppKit -lsqlite3 \
  $(find Tests/HalfLidCoreTests -name '*.swift' | sort) -o build/bin/halflid-tests
build/bin/halflid-tests
