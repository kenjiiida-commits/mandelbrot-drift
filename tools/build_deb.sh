#!/bin/bash
# web/index.html から Ubuntu 用の DEB パッケージを作る。できたものは dist/ に入る。
set -e
cd "$(dirname "$0")/.."
VER=$(grep '^Version:' packaging/deb/DEBIAN/control | cut -d' ' -f2)
WORK=$(mktemp -d)
cp -a packaging/deb "$WORK/pkg"
mkdir -p "$WORK/pkg/usr/share/mandelbrot-drift"
cp web/index.html "$WORK/pkg/usr/share/mandelbrot-drift/index.html"
chmod 755 "$WORK/pkg/usr/bin/mandelbrot-drift"
mkdir -p dist
dpkg-deb --root-owner-group --build "$WORK/pkg" "dist/mandelbrot-drift_${VER}_all.deb"
rm -rf "$WORK"
echo "できました: dist/mandelbrot-drift_${VER}_all.deb"
