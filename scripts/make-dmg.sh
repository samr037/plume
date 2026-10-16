#!/bin/sh
# Emballe une Plume.app dans un DMG glisser-déposer : make-dmg.sh <Plume.app> <sortie.dmg>
set -e
APP="$1"
OUT="$2"
[ -d "$APP" ] && [ -n "$OUT" ] || { echo "usage: make-dmg.sh <Plume.app> <sortie.dmg>"; exit 1; }
cd "$(dirname "$0")/.."

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Plume.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/Lisez-moi.txt"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "Plume" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT"
rm -rf "$STAGE"
echo "DMG : $OUT"
