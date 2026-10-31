import Foundation

/// 古い録音に共通する、回転むらで揺らす部分。左右に同じ揺れをかける（1 本のテープ・1 枚の盤なので）
private struct Wobbler {
  private var wow: WowFlutter
  private let delays: (ModulatedDelay, ModulatedDelay)

  init(_ wow: WowFlutter, sampleRate: Double) {
    self.wow = wow
    delays = (ModulatedDelay(maxDelaySeconds: wow.maxDelaySeconds, sampleRate: sampleRate),
              ModulatedDelay(maxDelaySeconds: wow.maxDelaySeconds, sampleRate: sampleRate))
  }

  @inline(__always)
  mutating func process(_ l: Float, _ r: Float) -> (Float, Float) {
    let d = wow.next()
    return (delays.0.process(l, delay: d), delays.1.process(r, delay: d))
  }

  mutating func reset() {
    wow.reset()
    delays.0.reset()
    delays.1.reset()
  }
}

/// LP レコード（33⅓ 回転）。
/// - 針が溝のほこりを拾う細かいチリチリ（左右の溝の壁で別々に鳴る）と、たまの大きなパチッ、1 回転ごとの傷のプツッ
/// - 盤面のかすかなサーが、1 回転（1.8 秒）ごとに少し強くなる
/// - 回転むらでわずかに揺れる音程
/// - 太めの低音と丸い高音、軽い歪み。低音は針飛びを防ぐためにカッティングでモノラルにまとめてある
final class VinylEffect: Effect {
  private var wobbler: Wobbler
  private var tone: [BiquadCascade]
  /// 低音の左右の差を消すため、左右の差（サイド）から低音を抜く
  private var sideHighPass: Biquad
  /// パチパチの音色。針先の小さな粒の音は高めで乾いている
  private var clickTone: [BiquadCascade]
  private var surface: [BiquadCascade]
  private var noise = NoiseGenerator(seed: 0x51A7_1A2B)
  private var ticks: (Crackle, Crackle)
  private var pops: Crackle
  private var scratch: RevolutionClick
  private var swish: RevolutionSwish

  init(sampleRate sr: Double) {
    wobbler = Wobbler(
      WowFlutter(
        baseDelay: 0.003,
        wobbles: [.init(frequency: 100.0 / 3 / 60, depth: 0.0004), .init(frequency: 7, depth: 0.00001)],
        drift: 0.0001, sampleRate: sr, seed: 0x33),
      sampleRate: sr)
    let stages: [Biquad] = [
      .highPass(25, sampleRate: sr), .highPass(25, sampleRate: sr),
      .lowShelf(200, gainDB: 2.5, sampleRate: sr),
      .lowPass(9500, sampleRate: sr), .lowPass(12000, sampleRate: sr),
    ]
    tone = [BiquadCascade(stages), BiquadCascade(stages)]
    sideHighPass = .highPass(150, sampleRate: sr)
    let clickStages: [Biquad] = [.highPass(900, sampleRate: sr), .lowPass(9000, sampleRate: sr)]
    clickTone = [BiquadCascade(clickStages), BiquadCascade(clickStages)]
    let surfaceStages: [Biquad] = [.highPass(400, sampleRate: sr), .lowPass(6000, sampleRate: sr)]
    surface = [BiquadCascade(surfaceStages), BiquadCascade(surfaceStages)]
    ticks = (Crackle(rate: 14, amplitude: 0.01...0.2, skew: 3, decayMs: 0.25, sampleRate: sr, seed: 0x71C5),
             Crackle(rate: 14, amplitude: 0.01...0.2, skew: 3, decayMs: 0.25, sampleRate: sr, seed: 0x71C6))
    pops = Crackle(rate: 0.4, amplitude: 0.12...0.3, decayMs: 0.8, sampleRate: sr, seed: 0x9095)
    scratch = RevolutionClick(revolutionsPerMinute: 100.0 / 3, amplitude: 0.12, decayMs: 0.5, sampleRate: sr, seed: 0x5C2A)
    swish = RevolutionSwish(revolutionsPerMinute: 100.0 / 3, depth: 0.3, sampleRate: sr)
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      var (l, r) = wobbler.process(left[i], right[i])
      // 低音をモノラルにまとめる（サイドの低音を抜く）
      let mid = 0.5 * (l + r)
      let side = sideHighPass.process(0.5 * (l - r))
      // ステレオの溝は左右が 1 本の溝の両壁なので、互いに少し漏れる
      (l, r) = (mid + 0.88 * side, mid - 0.88 * side)
      // 盤面の雑音と傷は左右に共通、細かいチリチリは左右の壁で別々
      let s = swish.next()
      let shared = pops.next() + scratch.next()
      let hissL = s * surface[0].process(0.006 * noise.next())
      let hissR = s * surface[1].process(0.006 * noise.next())
      let clickL = clickTone[0].process(ticks.0.next() + shared)
      let clickR = clickTone[1].process(ticks.1.next() + 0.8 * shared)
      // 0.62 は原音とだいたい同じ音量になる倍率（低音を持ち上げ、軽く歪ませた分を下げる）
      wetLeft[i] = 0.62 * saturate(tone[0].process(l), drive: 1.25) + hissL + clickL
      wetRight[i] = 0.62 * saturate(tone[1].process(r), drive: 1.25) + hissR + clickR
    }
  }

  func reset() {
    wobbler.reset()
    sideHighPass.reset()
    for i in 0..<2 {
      tone[i].reset()
      clickTone[i].reset()
      surface[i].reset()
    }
    ticks.0.reset()
    ticks.1.reset()
    pops.reset()
    scratch.reset()
  }
}

/// カセットテープ（普及型のデッキとノーマルテープ）。
/// 揺れ（モーターとキャプスタンのむら）、テープの磁気が飽和して丸まる大きい音、再生ヘッドで落ちる高音、
/// ヘッドの共振で少しふくらむ低音、ヒスノイズ、そしてまれにテープの傷で音が一瞬引っ込む（ドロップアウト）
final class CassetteEffect: Effect {
  private var wobbler: Wobbler
  /// 録音前に高音を持ち上げ、再生後に戻す。飽和は持ち上げた高音から先に起きるので、大きい音ほど高音がつぶれる
  private var emphasis: [Biquad]
  private var playback: [BiquadCascade]
  private var hiss: [BiquadCascade]
  private var noise = NoiseGenerator(seed: 0xCA55_E77E)
  private var dropoutTrigger = NoiseGenerator(seed: 0xD20F)
  private var dropout: Float = 0
  private let dropoutProbability: Float
  private let dropoutDecay: Float

  init(sampleRate sr: Double) {
    wobbler = Wobbler(
      WowFlutter(
        baseDelay: 0.004,
        wobbles: [.init(frequency: 0.9, depth: 0.0005), .init(frequency: 5, depth: 0.00003), .init(frequency: 13, depth: 0.00001)],
        drift: 0.0003, sampleRate: sr, seed: 0xCA55),
      sampleRate: sr)
    emphasis = Array(repeating: .highShelf(3000, gainDB: 6, sampleRate: sr), count: 2)
    let stages: [Biquad] = [
      .highShelf(3000, gainDB: -6, sampleRate: sr),
      .peaking(70, q: 1, gainDB: 2.5, sampleRate: sr),
      .lowPass(9000, sampleRate: sr), .lowPass(10000, sampleRate: sr),
      .highPass(30, sampleRate: sr),
    ]
    playback = [BiquadCascade(stages), BiquadCascade(stages)]
    // ヒスは音楽より 40 dB ほど小さく、再生ヘッドで高音が落ちる
    let hissStages: [Biquad] = [.highPass(1500, sampleRate: sr), .lowPass(12000, sampleRate: sr)]
    hiss = [BiquadCascade(hissStages), BiquadCascade(hissStages)]
    // 1 分に 3 回ほど、0.1 秒ほど音が引っ込む
    dropoutProbability = Float(0.05 / sr)
    dropoutDecay = Float(exp(-1 / (0.06 * sr)))
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      if (dropoutTrigger.next() + 1) / 2 < dropoutProbability {
        dropout = 0.6
      }
      dropout *= dropoutDecay
      let level = 1 - dropout

      let (l, r) = wobbler.process(left[i], right[i])
      let tapeL = saturate(emphasis[0].process(l), drive: 1.8) * level
      let tapeR = saturate(emphasis[1].process(r), drive: 1.8) * level
      // 0.58 は原音とだいたい同じ音量になる倍率（飽和の tanh は小さい音を 1.9 倍にするので、その分下げる）
      wetLeft[i] = 0.58 * playback[0].process(tapeL) + hiss[0].process(0.002 * noise.next())
      wetRight[i] = 0.58 * playback[1].process(tapeR) + hiss[1].process(0.002 * noise.next())
    }
  }

  func reset() {
    wobbler.reset()
    for i in 0..<2 {
      emphasis[i].reset()
      playback[i].reset()
      hiss[i].reset()
    }
    dropout = 0
  }
}

/// 蓄音機で聞く SP 盤（78 回転、電気を使わないラッパ式）を、部屋で聞く。
/// - モノラルで 300 Hz〜4 kHz ほど。ラッパの管の共鳴でいくつも山ができ、鼻にかかった音になる
/// - シェラック盤は粒が粗く、針音が大きい：「ザー」という盤面の雑音、細かい粒が絶えず鳴る「ジリジリ」、
///   大きめの粒の「ブツッ」、1 回転（0.77 秒）ごとに同じ傷で鳴る「プツッ」。どれも 1 回転ごとに強弱がつく
/// - 音はラッパから部屋に出て、壁の反射と一緒に聞こえる（音源は 1 か所でも、響きは周りに広がる）
final class GramophoneEffect: Effect {
  private var wobbler: Wobbler
  private var compressor: Compressor
  private var horn: BiquadCascade
  private var noise = NoiseGenerator(seed: 0x6A3A_0FED)
  /// ジリジリ：細かい粒がとても多い
  private var sizzle: Crackle
  /// ブツブツ：大きめの粒が 1 秒に数回
  private var pops: Crackle
  private var scratch: RevolutionClick
  private var swish: RevolutionSwish
  private let room: (left: PartitionedConvolver, right: PartitionedConvolver)

  init(sampleRate sr: Double) {
    wobbler = Wobbler(
      WowFlutter(baseDelay: 0.003, wobbles: [.init(frequency: 78.0 / 60, depth: 0.00025)], drift: 0.0001, sampleRate: sr, seed: 0x78),
      sampleRate: sr)
    compressor = Compressor(thresholdDB: -22, ratio: 3, attackMs: 10, releaseMs: 200, makeupDB: 6, sampleRate: sr)
    horn = BiquadCascade([
      .highPass(300, sampleRate: sr), .highPass(300, sampleRate: sr),
      .lowPass(4000, sampleRate: sr), .lowPass(4000, sampleRate: sr), .lowPass(4000, sampleRate: sr),
      .peaking(700, q: 3, gainDB: 6, sampleRate: sr),
      .peaking(1500, q: 3, gainDB: 7, sampleRate: sr),
      .peaking(2800, q: 4, gainDB: 5, sampleRate: sr),
    ])
    sizzle = Crackle(rate: 600, amplitude: 0.02...0.25, skew: 4, decayMs: 0.08, sampleRate: sr, seed: 0x5CA7)
    pops = Crackle(rate: 4, amplitude: 0.15...0.6, skew: 2, decayMs: 1.2, sampleRate: sr, seed: 0x9099)
    scratch = RevolutionClick(revolutionsPerMinute: 78, amplitude: 0.35, decayMs: 1.5, sampleRate: sr, seed: 0x78C1)
    swish = RevolutionSwish(revolutionsPerMinute: 78, depth: 0.35, sampleRate: sr)
    let ir = RoomImpulse.livingRoom.generate(sampleRate: sr)
    room = (PartitionedConvolver(impulse: ir.left, blockSize: 256), PartitionedConvolver(impulse: ir.right, blockSize: 256))
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      let (l, r) = wobbler.process(left[i], right[i])
      var x = 0.5 * (l + r)
      x = saturate(x * compressor.gain(level: abs(x)), drive: 1.5)
      // 針音も同じラッパを通って鳴るので、ラッパの前で足す
      x += swish.next() * (0.03 * noise.next() + sizzle.next()) + pops.next() + scratch.next()
      let y = horn.process(x)
      // ラッパから出た音（中央）と、部屋の響き（左右で違う）
      // 1.07 は原音とだいたい同じ音量になる倍率
      wetLeft[i] = 1.07 * (0.8 * y + 0.55 * room.left.process(y))
      wetRight[i] = 1.07 * (0.8 * y + 0.55 * room.right.process(y))
    }
  }

  func reset() {
    wobbler.reset()
    compressor.reset()
    horn.reset()
    sizzle.reset()
    pops.reset()
    scratch.reset()
    room.left.reset()
    room.right.reset()
  }
}
