#!/bin/bash
# Builds Half Lid with swiftc only: no SwiftPM, no Xcode, no third-party dependencies.
# (SwiftPM is not used because it is unusable on some Command Line Tools installs; see docs/FINDINGS.md.)
#
#   scripts/build.sh                 release build for this Mac's architecture
#   CONFIG=debug scripts/build.sh    debug build
#   ARCHS="arm64 x86_64" scripts/build.sh   universal binaries (the x86_64 slice is built but not run-tested)
#
# Output: build/bin/halflid (CLI), build/bin/HalfLidApp (menu bar executable), build/bin/HalfLidPanel (quick-actions panel,
# run only while open), build/bin/HalfLidSettings (settings window, run only while open), build/lib/ (the HalfLidCore library).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-$(uname -m)}"
OUT="build"
MIN_MACOS="14.0"
# SwiftUI is linked only into the settings window (a separate, on-demand executable): every linked framework is loaded at
# launch, so linking it into the always-running processes would cost memory for nothing.
FRAMEWORKS=(-framework IOKit -framework AppKit -lsqlite3)
SETTINGS_FRAMEWORKS=(-framework IOKit -framework AppKit -framework SwiftUI -lsqlite3)

OPT=(-O)
[ "$CONFIG" = "debug" ] && OPT=(-Onone -g)

CORE_SOURCES=$(find Sources/HalfLidCore -name '*.swift' | sort)
APP_SOURCES=$(find Sources/HalfLidApp -name '*.swift' | sort)
PANEL_SOURCES=$(find Sources/HalfLidPanel -name '*.swift' | sort)
SETTINGS_SOURCES=$(find Sources/HalfLidSettings -name '*.swift' | sort)
BINARIES=(halflid HalfLidApp HalfLidPanel HalfLidSettings)

rm -rf "$OUT/lib" "$OUT/bin" "$OUT/slices"
mkdir -p "$OUT/lib" "$OUT/bin"

for ARCH in $ARCHS; do
  SLICE="$OUT/slices/$ARCH"
  mkdir -p "$SLICE/lib" "$SLICE/bin"
  COMMON=(-swift-version 5 -target "$ARCH-apple-macos$MIN_MACOS" "${OPT[@]}")

  # shellcheck disable=SC2086
  swiftc "${COMMON[@]}" -parse-as-library -module-name HalfLidCore \
    -emit-module -emit-module-path "$SLICE/lib/HalfLidCore.swiftmodule" \
    -emit-library -static -o "$SLICE/lib/libHalfLidCore.a" $CORE_SOURCES

  LINK=(-I "$SLICE/lib" -L "$SLICE/lib" -lHalfLidCore "${FRAMEWORKS[@]}")
  swiftc "${COMMON[@]}" "${LINK[@]}" Sources/halflid/*.swift -o "$SLICE/bin/halflid"
  # shellcheck disable=SC2086
  swiftc "${COMMON[@]}" -parse-as-library "${LINK[@]}" $APP_SOURCES -o "$SLICE/bin/HalfLidApp"
  # shellcheck disable=SC2086
  swiftc "${COMMON[@]}" "${LINK[@]}" $PANEL_SOURCES -o "$SLICE/bin/HalfLidPanel"
  # shellcheck disable=SC2086
  swiftc "${COMMON[@]}" -parse-as-library -I "$SLICE/lib" -L "$SLICE/lib" -lHalfLidCore "${SETTINGS_FRAMEWORKS[@]}" \
    $SETTINGS_SOURCES -o "$SLICE/bin/HalfLidSettings"
done

FIRST_ARCH="${ARCHS%% *}"
cp -R "$OUT/slices/$FIRST_ARCH/lib/." "$OUT/lib/"
for BIN in "${BINARIES[@]}"; do
  # shellcheck disable=SC2086
  lipo -create $(for ARCH in $ARCHS; do echo "$OUT/slices/$ARCH/bin/$BIN"; done) -output "$OUT/bin/$BIN"
done
echo "Built ($CONFIG, $ARCHS): $OUT/bin/halflid  $OUT/bin/HalfLidApp  $OUT/bin/HalfLidPanel  $OUT/bin/HalfLidSettings"
