#!/usr/bin/env bash
# dmg を作り、Info.plist のバージョンで GitHub のリリース（タグ v<バージョン>）を作って dmg を添付する。
# 先にコミットして push しておく。リリースノートは引数で渡す（省略するとコミットから自動で作る）
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/make-dmg.sh"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Config/Info.plist")"
dmg="$root/build/ElsewhereSound-$version.dmg"
if [ $# -gt 0 ]; then
  gh release create "v$version" "$dmg" --title "Elsewhere Sound $version" --notes "$1"
else
  gh release create "v$version" "$dmg" --title "Elsewhere Sound $version" --generate-notes
fi
