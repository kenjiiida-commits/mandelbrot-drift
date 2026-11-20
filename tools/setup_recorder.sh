#!/bin/bash
# 録画のための Android 側のプログラム（MainActivity.kt・VideoRecorder.kt）を、
# このアプリの識別名に合わせて正しい場所に置く。録画ボタンを入れたあと1回だけ実行する。
set -e
cd "$(dirname "$0")/.."
MAIN=$(find android/app/src/main -name MainActivity.kt | head -1)
if [ -z "$MAIN" ]; then
  echo "android/app/src/main の中に MainActivity.kt が見つかりません。"
  exit 1
fi
PKG=$(grep -m1 '^package ' "$MAIN" | sed 's/^package //; s/[; ]//g')
DIR=$(dirname "$MAIN")
sed "s/^package PACKAGE_NAME/package $PKG/" tools/android/MainActivity.kt > "$DIR/MainActivity.kt"
sed "s/^package PACKAGE_NAME/package $PKG/" tools/android/VideoRecorder.kt > "$DIR/VideoRecorder.kt"
echo "録画のプログラムを置きました（識別名: $PKG）"
echo "  $DIR/MainActivity.kt"
echo "  $DIR/VideoRecorder.kt"
