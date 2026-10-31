#!/usr/bin/env bash
# 配布用の build/ElsewhereSound-<バージョン>.dmg を作る。
# 開くと「Elsewhere Sound.app」と「Applications」へのリンクが並び、アプリをリンクへドラッグすればインストールできる。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/build-app.sh"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Config/Info.plist")"
dmg="$root/build/ElsewhereSound-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$root/build/Elsewhere Sound.app" "$staging/Elsewhere Sound.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Elsewhere Sound" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
echo "built $dmg"
