#!/bin/bash
# アプリの識別名を、仮の com.example.mandelbrot_drift から正式な名前に変える。
# 公開前に1回だけ実行する。（2回実行しても問題はない）
set -e
cd "$(dirname "$0")/.."
OLD="com.example.mandelbrot_drift"
NEW="io.github.kenjiiida_commits.mandelbrot_drift"

# 設定ファイルとプログラムの中の名前を書き換える
grep -rlF "$OLD" android --include='*.gradle' --include='*.kts' --include='*.xml' --include='*.kt' --include='*.java' \
  | xargs -r sed -i "s/com\.example\.mandelbrot_drift/$NEW/g"

# MainActivity をフォルダごと新しい名前の場所へ移す
for lang in kotlin java; do
  OLDDIR="android/app/src/main/$lang/com/example/mandelbrot_drift"
  NEWDIR="android/app/src/main/$lang/io/github/kenjiiida_commits/mandelbrot_drift"
  if [ -d "$OLDDIR" ]; then
    mkdir -p "$NEWDIR"
    mv "$OLDDIR"/* "$NEWDIR"/
    rmdir -p --ignore-fail-on-non-empty "$OLDDIR" 2>/dev/null || true
  fi
done

echo "識別名を $NEW に変えました。書き換えた場所："
grep -rnF "$NEW" android --include='*.gradle' --include='*.kts' --include='*.kt' --include='*.java' || true
