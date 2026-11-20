#!/bin/bash
# GitHubへの反映を1回で行う。
# 使い方:  bash tools/release.sh 版の番号 "変更の説明"
# 例:      bash tools/release.sh 1.7.0 "3つの景色・見回す・環境音を追加"
set -e
cd "$(dirname "$0")/.."

VER="$1"
NOTE="${2:-マンデルブロ・ドリフト $VER}"
if [ -z "$VER" ]; then
  echo "版の番号を付けてください。例: bash tools/release.sh 1.7.0 \"変更の説明\""
  exit 1
fi
if gh release view "v$VER" >/dev/null 2>&1; then
  echo "v$VER はもうGitHubに載っています。新しい番号にしてください。"
  exit 1
fi

echo "== 1/6 版の番号を $VER にしています"
# スマホが「新しい版」と分かるように、通し番号は日時から作る（前より必ず大きくなる）
OLD=$(grep '^version:' pubspec.yaml | sed 's/.*+//')
BUILD=$((10#$(date +%y%j%H)))
if [ "$BUILD" -le "$OLD" ]; then BUILD=$((OLD + 1)); fi
sed -i "s/^version: .*/version: $VER+$BUILD/" pubspec.yaml
sed -i "s/^Version: .*/Version: $VER/" packaging/deb/DEBIAN/control

echo "== 2/6 Android用のAPKを作っています（数分かかります）"
flutter build apk --release
APK="$HOME/mandelbrot-drift_$VER.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$APK"

echo "== 3/6 Ubuntu用のDEBを作っています"
bash tools/build_deb.sh
DEB="$HOME/mandelbrot-drift_${VER}_all.deb"
mv "dist/mandelbrot-drift_${VER}_all.deb" "$DEB"
rmdir dist 2>/dev/null || true

echo "== 4/6 変更を記録しています"
git add .
git commit -m "$NOTE（$VER）" || echo "（記録する変更はありませんでした）"

echo "== 5/6 GitHubに送っています"
git push

echo "== 6/6 配布ファイルを載せています"
gh release create "v$VER" "$APK" "$DEB" --title "マンデルブロ・ドリフト $VER" --notes "$NOTE"

echo ""
echo "完了しました。"
echo "  APK: $APK"
echo "  DEB: $DEB"
echo "  ページ: https://github.com/kenjiiida-commits/mandelbrot-drift/releases/tag/v$VER"
