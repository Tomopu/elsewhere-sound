#!/usr/bin/env bash
# build/Elsewhere Sound.app を組み立てて、Hardened Runtime つきで ad-hoc 署名する。
# 自分の Mac で使うだけなら、Apple Developer Program の証明書も期限もない。
# 作り直すと署名が変わるので、システム音声の録音の許可をもう一度聞かれることがある。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Apple シリコンと Intel の両方で動くユニバーサルバイナリにする
arch=(--arch arm64 --arch x86_64)
swift build -c release "${arch[@]}" --package-path "$root"
bin="$(swift build -c release "${arch[@]}" --package-path "$root" --show-bin-path)/ElsewhereSound"
app="$root/build/Elsewhere Sound.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# SwiftPM はバイナリに SDK バージョンとして最小対応 OS を書き込み、macOS が旧来の見た目の互換モードで表示するので、実際の SDK バージョンに直す
sdk="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos 15.0 "$sdk" -replace -output "$app/Contents/MacOS/ElsewhereSound" "$bin" 2>/dev/null
cp "$root/Config/Info.plist" "$app/Contents/Info.plist"
# Icon Composer のアイコンから Assets.car（macOS 26 以降）と AppIcon.icns（それより前）を作る
xcrun actool "$root/Resources/AppIcon.icon" --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist /dev/null >/dev/null
codesign --force --options runtime --sign - "$app"
codesign --verify --strict "$app"
echo "built $app"
