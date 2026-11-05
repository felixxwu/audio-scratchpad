#!/bin/zsh
# Regenerates the Mac and Windows app icons from the logo SVGs. The results are checked in, so builds don't need this.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
xcrun --sdk macosx swiftc -O render.swift -o "$work/render"

mkdir "$work/AppIcon.iconset"
for size in 16 32 128 256 512; do
  "$work/render" mac-icon.svg $size "$work/AppIcon.iconset/icon_${size}x${size}.png"
  "$work/render" mac-icon.svg $((size * 2)) "$work/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$work/AppIcon.iconset" -o AppIcon.icns

for size in 16 24 32 48 64 256; do "$work/render" logo.svg $size "$work/$size.png"; done
python3 - "$work" <<'PY'
import struct, sys
sizes = [16, 24, 32, 48, 64, 256]
pngs = [open(f"{sys.argv[1]}/{s}.png", "rb").read() for s in sizes]
out = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for size, png in zip(sizes, pngs):
    out += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
open("app.ico", "wb").write(out + b"".join(pngs))
PY
rm -rf "$work"
