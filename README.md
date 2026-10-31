# Elsewhere Sound

YouTube や Apple Music など、Mac から出る音すべてを、コンサートホールや大聖堂・映画館の客席、ラジオや電話、レコードやカセットテープで聞いているような音に変える、メニューバー常駐アプリ。プリセットは 12 個。

## インストール

macOS 15 以降（Apple シリコン・Intel のどちらでも）。

1. [Releases](https://github.com/Tomopu/ElsewhereSound/releases/latest) から `ElsewhereSound-<バージョン>.dmg` をダウンロードして開き、「Elsewhere Sound」を「Applications」へドラッグする
2. アプリランチャーや Finder から開く。Apple の公証（Developer ID の署名）を受けていないので、初回は「開けません」と止められる。
   システム設定 →「プライバシーとセキュリティ」の下の方にある「このまま開く」を押すと、次から普通に開ける。
   ターミナルなら次の 1 行でも同じになる

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Elsewhere Sound.app"
   ```

3. メニューバーのパネルでオンにして、「システムオーディオ録音」の許可を求められたら許可する

## ビルドと実行

```bash
swift test                    # 音の加工（ElsewhereSoundDSP）のテスト
./scripts/build-app.sh        # build/Elsewhere Sound.app を作る（ad-hoc 署名 + Hardened Runtime）
./scripts/install-app.sh      # ビルドして /Applications に入れて起動する（アプリランチャーや Spotlight から開ける）
./scripts/make-dmg.sh         # 配布用の build/ElsewhereSound-<バージョン>.dmg を作る
./scripts/release.sh          # dmg を作り、GitHub に v<バージョン> のリリースを作って添付する（先に push しておく）
```

ビルドは Apple シリコンと Intel の両方で動くユニバーサルバイナリ。バージョンは `Config/Info.plist` の `CFBundleShortVersionString`。

ランチャーや Finder から開くと、メニューバーのパネルが開く。アイコンは Icon Composer 形式（`Resources/AppIcon.icon`）で、ビルド時に `actool` で Assets.car と AppIcon.icns にする。

初めてオンにしたとき、macOS が「システムオーディオ録音」の許可を求める。許可しないと入力が無音になる（あとから システム設定 →「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で変えられる）。
アプリを作り直すと署名が変わるので、もう一度聞かれることがある。

開発用：

```bash
# 音声ファイルを変換して、加工だけを耳で確かめる（強さは省略可）
# プリセット名：hall cathedral jazz stadium cinema nextroom fm am phone vinyl cassette gramophone
"build/Elsewhere Sound.app/Contents/MacOS/ElsewhereSound" --render vinyl 入力.wav 出力.wav [0〜1]
# 操作パネルをライト・ダークで PNG に描き出す（デバッグビルドだけ）
swift run ElsewhereSound --snapshot 出力先フォルダ
# 入出力の最大振幅を 1 秒に 15 回ログに書く
open --env ELSEWHERE_LOG_LEVELS=1 --stdout /tmp/elsewhere-sound.log "build/Elsewhere Sound.app"
# 開始・失敗・壊れた値を直した記録を、macOS のログから読む（ランチャーから開いたときも残る）
/usr/bin/log show --predicate 'subsystem == "com.tomopu.ElsewhereSound"' --last 1h
```

## 仕組み

```
他のアプリの音 ──Process Tap（元の音はミュート）──┐
                                                  ├─ 集約デバイスの IOProc ─ Processor ─ スピーカー
いまの出力先（スピーカー・ヘッドホン）────────────┘
```

- Core Audio の Process Tap（macOS 14.2〜）で、このアプリ以外の全プロセスの音をステレオで受け取る。受け取っている間は元の音を鳴らさない（アプリが落ちれば元に戻る）
- Tap と出力先を 1 つの非公開の集約デバイスにまとめ、その IOProc の中で入力を加工して出力へ書く。遅れは IO 1 回分（＋ホールの響きだけ 512 サンプル）
- このアプリ自身の音は Tap から外しているので、加工した音を拾い直して回り続けることはない
- 出力先が変わったら（ヘッドホンを挿したなど）作り直す
- 取り込んだ音に NaN や無限大が 1 つでも混ざると、フィルタ・響き・リミッターの中に残り続けて、ビリビリした音や無音のまま戻らなくなる。動画を飛ばしたときなどに混ざることがあるので、加工の前に 0 や ±4 に直す。それでも加工の途中で値が壊れたら、そのプリセットとリミッターの状態を消してやり直す。どちらも回数を macOS のログに残す

## プリセット

| グループ | プリセット | 中身 |
|---|---|---|
| 響く場所 | コンサートホール | 計算で作ったインパルス応答（初期反射 + 帯域ごとに減衰する残響。RT60 は低 2.4 秒・中 2.0 秒・高 1.1 秒）を FFT で畳み込む。響く場所の響きはどれも、300 Hz あたりのこもりを少し削って原音の声や歓声を覆わないようにしている |
| | 大聖堂・教会 | RT60 は低 7 秒・中 6 秒・高 4 秒。石は高音もあまり吸わないので、高音まで長く残る |
| | ジャズクラブ | RT60 0.8 秒ほど、反射がすぐ来る狭い部屋。響きの低音を 4 dB 持ち上げる |
| | 野外ライブ・スタジアム | 響きは薄く（残響のレベルを下げる）、0.33 秒と 0.66 秒に向かいのスタンドからのやまびこ。直接音は少し小さく、響きは高音が少し落ちている（歓声が遠くならない程度） |
| | 映画館 | 吸音された広い部屋の短い響き（RT60 中 0.7 秒）、サブウーファーの重い低音（90 Hz 以下を +6 dB）、左右の差の成分を 17・23 ms 遅らせて足すサラウンドの広がり、スクリーン越しで少し落ち着いた高音 |
| | 隣の部屋 | 隣の部屋の響き（RT60 0.45 秒）ごと、壁を通した音。380 Hz より上をほとんど通さず、110 Hz に壁の共鳴、左右はほぼ同じ |
| ラジオ・電話 | FM ラジオ | 40 Hz〜14.5 kHz。3 帯域のコンプレッサーとリミッターで放送局のように音圧をそろえ、左右を少し混ぜ、かすかなヒスノイズ |
| | AM ラジオ | モノラル、120 Hz〜3.5 kHz。強い圧縮と歪み、受信機を通った雑音、まれな空電の「パチッ」、電波のゆらぎ、小さなスピーカーの中域の山 |
| | 電話・トランシーバー | モノラル、300 Hz〜3.4 kHz。8 kHz で取り直し、μ-law で 7 ビットに丸める粗さがザラつきになる。受話器の 1.8 kHz の山 |
| 古い録音 | レコード | 33⅓ 回転の 1 回転ごとの揺れと細かいフラッター、左右の溝で別々に鳴るチリチリ（小さい粒ほど多い）とたまのパチッ、1 回転ごとに同じ傷で鳴るプツッ、1 回転ごとに強弱のつく盤面のサー、太めの低音（150 Hz 以下はモノラル）と丸い高音、軽い歪み |
| | カセットテープ | 揺れ（周期的なものと不規則なもの）、高音から先に飽和するテープ、9 kHz あたりからの高音落ち、70 Hz のヘッドの共振、ヒス、まれなドロップアウト |
| | 蓄音機（SP 盤） | 78 回転の揺れ、300 Hz〜4 kHz、ラッパの共鳴（700 Hz・1.5 kHz・2.8 kHz）。針音は曲より 17 dB ほど小さいだけの大きさで、盤面のザー、細かい粒が絶えず鳴るジリジリ（1 秒に 600 粒）、大きめの粒のブツブツ、1 回転ごとの傷のプツッ。音源はモノラルだが、部屋の響きを足して周りに広がる |

- 響く場所（ホール・大聖堂・ジャズクラブ・スタジアム）の「強さ」は客席の位置。上げるほど直接音が減り、響きが増える。初めて使うときは中ほどの 50%（スタジアムだけは、実況の声が埋もれない 64%）。そのほかは原音を加工した音に置き換えていく割合
- 音量はテスト用の曲のラウドネス（LUFS）で、どのプリセットも原音との差を 1 LU 以内に合わせてある（隣の部屋だけ壁越しなので 1 LU 小さい）
- 設定に保存するプリセットの番号（`Preset` の rawValue）は、追加したものほど後ろの番号。並び順とは別

## 構成

| 場所 | 役割 |
|---|---|
| `Sources/ElsewhereSoundDSP/` | 音の加工。部品はフィルタ（`Biquad`）、コンプレッサー・歪み・乱数（`Dynamics`）、分割畳み込み（`Convolver`）、部屋のインパルス応答（`RoomImpulse`）、回転むら・パチパチ（`Texture`）。プリセットごとの加工は `Effects`（一覧）と、響く場所（`RoomEffects`）・ラジオと電話（`RadioEffects`）・古い録音（`RecordingEffects`）。プリセットの一覧と切り替え・混ぜ合わせは `Processor`（画面とオーディオスレッドの受け渡しは Atomic だけ） |
| `Sources/ElsewhereSound/Audio/` | Process Tap と集約デバイス（`SystemAudioTap`）、Core Audio のプロパティ読み取り（`CoreAudioProperty`）、画面との橋渡し（`AudioController`） |
| `Sources/ElsewhereSound/App/` | 入口とメニューバー、起動時にパネルを開く（`ElsewhereSoundApp`）、操作パネル（`ControlPanel`）、ファイル変換（`FileRenderer`） |
| `Resources/AppIcon.icon` | アプリのアイコン（ヘッドホンと音の波形。Icon Composer で開ける） |
| `Sources/ElsewhereSound/Debug/` | 操作パネルの撮影（`--snapshot`。DEBUG ビルドだけ） |
| `Tests/ElsewhereSoundDSPTests/` | 畳み込みが直接計算と一致すること、各プリセットの帯域・残響の長さ・やまびこ・切り替え時の段差、回転むらとパチパチの部品、NaN や無限大が来ても立ち直ることなど |
