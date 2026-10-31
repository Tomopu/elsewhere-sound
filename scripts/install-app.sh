#!/usr/bin/env bash
# ビルドして /Applications に入れ、起動する。/Applications に入れるとアプリランチャーや Spotlight から開ける。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/build-app.sh"
# 動いているものを終わらせてから入れ替える（オーディオの Tap と集約デバイスを片付けさせるため、強制終了はしない）
osascript -e 'quit app id "com.tomopu.ElsewhereSound"' 2>/dev/null || true
rm -rf "/Applications/Elsewhere Sound.app"
ditto "$root/build/Elsewhere Sound.app" "/Applications/Elsewhere Sound.app"
# Launch Services にすぐ知らせて、ランチャーにアイコンが出るのを待たずに済むようにする
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Elsewhere Sound.app"
open "/Applications/Elsewhere Sound.app"
echo "installed /Applications/Elsewhere Sound.app"
