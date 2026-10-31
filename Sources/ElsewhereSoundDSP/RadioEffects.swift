import Foundation

/// FM ラジオ。放送局の音作り（帯域ごとに強く圧縮して音圧をそろえる）と、15 kHz までの帯域
final class FMRadioEffect: Effect {
  private struct Channel {
    var input: BiquadCascade
    var lowBand: BiquadCascade
    var restBand: BiquadCascade
    var midBand: BiquadCascade
    var highBand: BiquadCascade
    var output: BiquadCascade
  }

  private var channels: [Channel]
  private var low: Compressor
  private var mid: Compressor
  private var high: Compressor
  private var limiter: Compressor
  private var noise = NoiseGenerator(seed: 0xF0F0_1234)

  init(sampleRate: Double) {
    let sr = sampleRate
    // 帯域の分け目は 2 段重ねの Butterworth（Linkwitz–Riley）。足し戻すと元の音量に戻る
    let channel = Channel(
      input: BiquadCascade([
        .highPass(40, sampleRate: sr), .highPass(40, sampleRate: sr),
        // FM のプリエンファシスと放送局の EQ で、高い音が少し明るく聞こえる
        .highShelf(5000, gainDB: 2.5, sampleRate: sr),
      ]),
      lowBand: BiquadCascade(repeating: .lowPass(220, sampleRate: sr), count: 2),
      restBand: BiquadCascade(repeating: .highPass(220, sampleRate: sr), count: 2),
      midBand: BiquadCascade(repeating: .lowPass(3200, sampleRate: sr), count: 2),
      highBand: BiquadCascade(repeating: .highPass(3200, sampleRate: sr), count: 2),
      // FM 放送の音声は 15 kHz まで（19 kHz にステレオのパイロット信号があるため）
      output: BiquadCascade(repeating: .lowPass(14500, sampleRate: sr), count: 4))
    channels = [channel, channel]
    low = Compressor(thresholdDB: -24, ratio: 4, attackMs: 12, releaseMs: 250, makeupDB: 8, sampleRate: sr)
    mid = Compressor(thresholdDB: -24, ratio: 4, attackMs: 6, releaseMs: 160, makeupDB: 8, sampleRate: sr)
    high = Compressor(thresholdDB: -28, ratio: 5, attackMs: 2, releaseMs: 100, makeupDB: 10, sampleRate: sr)
    limiter = Compressor(thresholdDB: -8, ratio: 12, attackMs: 0.5, releaseMs: 60, kneeDB: 3, sampleRate: sr)
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      var l = channels[0].input.process(left[i])
      var r = channels[1].input.process(right[i])
      // FM ステレオの左右の分離は完全ではないので、少しだけ混ぜる
      (l, r) = (0.92 * l + 0.08 * r, 0.92 * r + 0.08 * l)

      let restL = channels[0].restBand.process(l)
      let restR = channels[1].restBand.process(r)
      let bands = (
        low: (channels[0].lowBand.process(l), channels[1].lowBand.process(r)),
        mid: (channels[0].midBand.process(restL), channels[1].midBand.process(restR)),
        high: (channels[0].highBand.process(restL), channels[1].highBand.process(restR)))
      let gLow = low.gain(level: max(abs(bands.low.0), abs(bands.low.1)))
      let gMid = mid.gain(level: max(abs(bands.mid.0), abs(bands.mid.1)))
      let gHigh = high.gain(level: max(abs(bands.high.0), abs(bands.high.1)))
      l = bands.low.0 * gLow + bands.mid.0 * gMid + bands.high.0 * gHigh
      r = bands.low.1 * gLow + bands.mid.1 * gMid + bands.high.1 * gHigh

      // 最後に頭を揃えて軽くクリップさせる。FM 局の「張り付いたような」音圧の正体
      let gLimit = limiter.gain(level: max(abs(l), abs(r)))
      let hiss = 0.0004 * noise.next()
      // 0.59 は原音とだいたい同じ音量になる倍率（テスト用の曲でラウドネス（LUFS）を合わせた。ほかのプリセットも同じ）
      wetLeft[i] = 0.59 * channels[0].output.process(saturate(l * gLimit, drive: 1.6) + hiss)
      wetRight[i] = 0.59 * channels[1].output.process(saturate(r * gLimit, drive: 1.6) + hiss)
    }
  }

  func reset() {
    for i in channels.indices {
      channels[i].input.reset()
      channels[i].lowBand.reset()
      channels[i].restBand.reset()
      channels[i].midBand.reset()
      channels[i].highBand.reset()
      channels[i].output.reset()
    }
    low.reset()
    mid.reset()
    high.reset()
    limiter.reset()
  }
}

/// AM ラジオ。モノラルで、だいたい 150 Hz〜3.5 kHz。強い圧縮、歪み、雑音、電波のゆらぎ、小さなスピーカーの癖
final class AMRadioEffect: Effect {
  private var station: BiquadCascade
  private var compressor: Compressor
  private var receiver: BiquadCascade
  private var speaker: BiquadCascade
  private var noise = NoiseGenerator(seed: 0xA0A0_5678)
  /// 空電の「パチッ」（1 秒に 1 回ほど）
  private var crackle: Crackle
  private var fadingPhase: Double = 0
  private let fadingStep: Double

  init(sampleRate: Double) {
    let sr = sampleRate
    station = BiquadCascade(repeating: .highPass(120, sampleRate: sr), count: 2)
    compressor = Compressor(thresholdDB: -30, ratio: 8, attackMs: 3, releaseMs: 250, makeupDB: 16, sampleRate: sr)
    crackle = Crackle(rate: 0.8, amplitude: 0.12...0.32, decayMs: 4, sampleRate: sr, seed: 0xA11CE)
    // 受信機の中間周波フィルタ。雑音もここを通るので、こもった「サー」になる
    receiver = BiquadCascade(repeating: .lowPass(3500, sampleRate: sr), count: 3)
    // 小さなスピーカーは低音が出ず、中域に山がある
    speaker = BiquadCascade([
      .highPass(220, sampleRate: sr),
      .peaking(1300, q: 1.1, gainDB: 5, sampleRate: sr),
    ])
    // 電離層の状態で、受信の強さが数秒おきにゆっくり変わる
    fadingStep = 2 * Double.pi * 0.17 / sr
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      var x = station.process(0.5 * (left[i] + right[i]))
      x = saturate(x * compressor.gain(level: abs(x)), drive: 2.2)
      x += 0.012 * noise.next() + crackle.next()

      let fading = 1 - 0.07 * Float(1 + sin(fadingPhase))
      fadingPhase += fadingStep
      if fadingPhase > 2 * Double.pi { fadingPhase -= 2 * Double.pi }

      // 0.52 は原音とだいたい同じ音量になる倍率
      let y = 0.52 * fading * speaker.process(receiver.process(x))
      wetLeft[i] = y
      wetRight[i] = y
    }
  }

  func reset() {
    station.reset()
    compressor.reset()
    receiver.reset()
    speaker.reset()
    crackle.reset()
  }
}

/// 電話・トランシーバー。モノラルで 300 Hz〜3.4 kHz。
/// 電話の音声は 8 kHz で標本化され、少ないビット数（μ-law）で記録される。その粗さが「ザラつき」になる
final class TelephoneEffect: Effect {
  private var band: BiquadCascade
  private var compressor: Compressor
  private var earpiece: BiquadCascade
  private var noise = NoiseGenerator(seed: 0x7E1E_F0E5)
  /// 8 kHz ごとに値を取り直し、その間は同じ値を保つ
  private let holdStep: Double
  private var holdPhase: Double = 1
  private var held: Float = 0

  init(sampleRate sr: Double) {
    band = BiquadCascade([
      .highPass(300, sampleRate: sr), .highPass(300, sampleRate: sr),
      .lowPass(3400, sampleRate: sr), .lowPass(3400, sampleRate: sr), .lowPass(3400, sampleRate: sr),
    ])
    compressor = Compressor(thresholdDB: -26, ratio: 4, attackMs: 5, releaseMs: 120, makeupDB: 12, sampleRate: sr)
    // 受話器の小さなスピーカーの山。8 kHz で取り直したときの折り返し（4 kHz より上の金属的な音）は、
    // 本物の電話と同じく受話側で切る。ザラつきは帯域の中に残る量子化の粗さで出る
    earpiece = BiquadCascade([
      .peaking(1800, q: 1.2, gainDB: 4, sampleRate: sr),
      .lowPass(3800, sampleRate: sr), .lowPass(3800, sampleRate: sr), .lowPass(3800, sampleRate: sr),
    ])
    holdStep = 8000 / sr
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      var x = band.process(0.5 * (left[i] + right[i]))
      x = min(max(x * compressor.gain(level: abs(x)), -1), 1)
      holdPhase += holdStep
      if holdPhase >= 1 {
        holdPhase -= 1
        held = Self.muLaw(x + 0.002 * noise.next())
      }
      // 0.93 は原音とだいたい同じ音量になる倍率
      let y = 0.93 * earpiece.process(held)
      wetLeft[i] = y
      wetRight[i] = y
    }
  }

  /// μ-law で圧縮して 7 ビット（符号つき）に丸め、元に戻す。小さい音ほど細かく、大きい音ほど粗く丸まる
  private static func muLaw(_ x: Float) -> Float {
    let mu: Float = 255
    let levels: Float = 63
    let compressed = log(1 + mu * abs(x)) / log(1 + mu)
    let quantized = (compressed * levels).rounded() / levels
    let expanded = (pow(1 + mu, quantized) - 1) / mu
    return x < 0 ? -expanded : expanded
  }

  func reset() {
    band.reset()
    compressor.reset()
    earpiece.reset()
    holdPhase = 1
    held = 0
  }
}
