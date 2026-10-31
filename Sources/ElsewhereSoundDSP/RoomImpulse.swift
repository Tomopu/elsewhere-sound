import Foundation

/// 部屋のインパルス応答（手を叩いた音が聞き手にどう届くか）を計算で作る。
///
/// 実際の部屋の響きは、大まかに次の 3 つでできている。
/// - 初期反射：壁や天井で 1〜2 回はね返った音。直接音から数十 ms 以内に、まばらに届く
/// - 残響：何度も反射して混ざり合った音。ノイズのように密で、指数関数的に小さくなる。
///   ふつうは高い音ほど壁や空気に吸われて早く消える
/// - やまびこ：遠くの大きな壁から、はっきり遅れて返ってくる音（野外やスタジアム）
/// 残響の長さ（RT60：60 dB 小さくなるまでの秒数）は低・中・高の帯域ごとに決める。
public struct RoomImpulse: Sendable {
  public struct Echo: Sendable {
    public var delay: Double
    public var gain: Float
  }

  /// 直接音から響きが始まるまで（秒）
  public var preDelay: Double
  /// 帯域ごとの残響時間（秒）
  public var rt60Low: Double
  public var rt60Mid: Double
  public var rt60High: Double
  /// 初期反射の数と、それが届く時間の幅（秒）
  public var earlyReflections: Int
  public var earlySpread: Double
  /// 残響が立ち上がるまでの時間（秒）。広い部屋ほど反射が重なるのに時間がかかる
  public var buildUp: Double
  /// 初期反射に対する残響の大きさ。野外のように響きが薄い場所では小さくする
  public var tailLevel: Float = 0.25
  public var echoes: [Echo] = []

  /// 大きめのコンサートホールの客席中ほど
  public static let concertHall = RoomImpulse(
    preDelay: 0.024, rt60Low: 2.4, rt60Mid: 2.0, rt60High: 1.1,
    earlyReflections: 18, earlySpread: 0.08, buildUp: 0.06)
  /// 石造りの大聖堂。硬い石は高い音もあまり吸わないので、高音まで長く残る
  public static let cathedral = RoomImpulse(
    preDelay: 0.04, rt60Low: 7.0, rt60Mid: 6.0, rt60High: 4.0,
    earlyReflections: 24, earlySpread: 0.15, buildUp: 0.15)
  /// 狭いジャズクラブ。壁が近いので反射がすぐ来て、響きは短い
  public static let jazzClub = RoomImpulse(
    preDelay: 0.008, rt60Low: 1.1, rt60Mid: 0.8, rt60High: 0.5,
    earlyReflections: 14, earlySpread: 0.03, buildUp: 0.02)
  /// スタジアム。屋根が開いているので響きは薄く、向かいのスタンドからやまびこが返る
  public static let stadium = RoomImpulse(
    preDelay: 0.05, rt60Low: 3.0, rt60Mid: 2.4, rt60High: 1.0,
    earlyReflections: 6, earlySpread: 0.06, buildUp: 0.1, tailLevel: 0.1,
    echoes: [Echo(delay: 0.33, gain: 0.45), Echo(delay: 0.66, gain: 0.2)])
  /// 映画館。広いが、壁も客席も音を吸うように作られていて、響きは短く素直
  public static let cinema = RoomImpulse(
    preDelay: 0.02, rt60Low: 1.0, rt60Mid: 0.7, rt60High: 0.5,
    earlyReflections: 8, earlySpread: 0.05, buildUp: 0.04, tailLevel: 0.2)
  /// 家具のある普通の部屋
  public static let livingRoom = RoomImpulse(
    preDelay: 0.003, rt60Low: 0.5, rt60Mid: 0.45, rt60High: 0.3,
    earlyReflections: 10, earlySpread: 0.02, buildUp: 0.01)

  /// 左右で別々の乱数を使い、広がりのある響きにする。どちらもエネルギーを 1 にそろえて返す
  public func generate(sampleRate: Double) -> (left: [Float], right: [Float]) {
    (channel(sampleRate: sampleRate, seed: 0x1234_5678, echoOffset: 0),
     channel(sampleRate: sampleRate, seed: 0x0BAD_F00D, echoOffset: 0.027))
  }

  private func channel(sampleRate: Double, seed: UInt32, echoOffset: Double) -> [Float] {
    let tailSeconds = max(rt60Low, rt60Mid, rt60High, (echoes.map(\.delay).max() ?? 0) + echoOffset + 0.05)
    let length = Int((preDelay + tailSeconds) * sampleRate)
    let start = Int(preDelay * sampleRate)
    var ir = [Float](repeating: 0, count: length)
    var noise = NoiseGenerator(seed: seed)

    // 初期反射：earlySpread の間に、だんだん小さくなるパルスを散らす
    for _ in 0..<earlyReflections {
      let r = (noise.next() + 1) / 2
      let delay = 0.003 + earlySpread * Double(r * r)
      let index = start + Int(delay * sampleRate)
      let gain = Float(0.5 * exp(-delay / (earlySpread * 0.65))) * (noise.next() < 0 ? -1 : 1)
      if index < length { ir[index] += gain }
    }

    // やまびこ：2 ms ほどにわずかに散った、はっきりした反射。左右で少し時間をずらす
    for echo in echoes {
      let index = start + Int((echo.delay + echoOffset) * sampleRate)
      for (k, g) in [Float(1), 0.6, 0.35].enumerated() {
        let i = index + k * Int(0.0008 * sampleRate)
        if i < length { ir[i] += echo.gain * g }
      }
    }

    // 残響：ノイズを 1 次フィルタで低・中・高に分け、帯域ごとの速さで減衰させる
    let lowCut = onePoleCoefficient(400, sampleRate)
    let highCut = onePoleCoefficient(3500, sampleRate)
    var lowState: Float = 0
    var highState: Float = 0
    let decayLow = decayPerSample(rt60Low, sampleRate)
    let decayMid = decayPerSample(rt60Mid, sampleRate)
    let decayHigh = decayPerSample(rt60High, sampleRate)
    var envLow: Float = 1, envMid: Float = 1, envHigh: Float = 1
    let buildUpSamples = Float(buildUp * sampleRate)
    for i in start..<length {
      let n = noise.next()
      lowState += lowCut * (n - lowState)
      highState += highCut * (n - highState)
      let low = lowState
      let high = n - highState
      let mid = n - low - high
      let onset = min(1, Float(i - start) / buildUpSamples)
      ir[i] += tailLevel * onset * (low * envLow + mid * envMid + high * envHigh)
      envLow *= decayLow
      envMid *= decayMid
      envHigh *= decayHigh
    }

    let energy = ir.reduce(0) { $0 + $1 * $1 }
    let normalize = 1 / energy.squareRoot()
    return ir.map { $0 * normalize }
  }

  private func onePoleCoefficient(_ frequency: Double, _ sampleRate: Double) -> Float {
    Float(1 - exp(-2 * Double.pi * frequency / sampleRate))
  }

  /// rt60 秒で振幅が 1/1000（-60 dB）になる 1 サンプルあたりの倍率
  private func decayPerSample(_ rt60: Double, _ sampleRate: Double) -> Float {
    Float(pow(0.001, 1 / (rt60 * sampleRate)))
  }
}
