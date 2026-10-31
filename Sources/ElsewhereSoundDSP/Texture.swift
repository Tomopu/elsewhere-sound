import Foundation

/// 遅れの長さを毎サンプル変えられる遅延。遅れを揺らすと音程がわずかに揺れる（レコードやテープの回転むら）
public final class ModulatedDelay {
  private let buffer: UnsafeMutablePointer<Float>
  private let capacity: Int
  private var writeIndex = 0

  public init(maxDelaySeconds: Double, sampleRate: Double) {
    capacity = Int(maxDelaySeconds * sampleRate) + 4
    buffer = .allocate(capacity: capacity)
    buffer.initialize(repeating: 0, count: capacity)
  }

  deinit {
    buffer.deallocate()
  }

  /// x を書き込み、delay サンプル前の値を線形補間で読む
  @inline(__always)
  public func process(_ x: Float, delay: Float) -> Float {
    buffer[writeIndex] = x
    let position = Float(writeIndex) - min(max(delay, 0), Float(capacity - 2))
    let wrapped = position < 0 ? position + Float(capacity) : position
    let i0 = Int(wrapped)
    let i1 = i0 + 1 == capacity ? 0 : i0 + 1
    let frac = wrapped - Float(i0)
    writeIndex = writeIndex + 1 == capacity ? 0 : writeIndex + 1
    return buffer[i0] + frac * (buffer[i1] - buffer[i0])
  }

  public func reset() {
    buffer.update(repeating: 0, count: capacity)
    writeIndex = 0
  }
}

/// 回転むら。ModulatedDelay に渡す遅れ（サンプル数）を作る。
/// 周期的な揺れ（ワウ：1 Hz 前後、フラッター：数 Hz 以上）と、ゆっくりした不規則な揺れを足し合わせる
public struct WowFlutter {
  public struct Wobble {
    public var frequency: Double
    /// 遅れの振れ幅（秒）。音程の揺れは 2π × frequency × depth（0.1% なら 0.001）
    public var depth: Double

    public init(frequency: Double, depth: Double) {
      self.frequency = frequency
      self.depth = depth
    }
  }

  private let base: Float
  private let depths: [Float]
  private let steps: [Double]
  private var phases: [Double]
  private let driftDepth: Float
  private let driftSmoothing: Float
  private let driftInterval: Int
  private var drift: Float = 0
  private var driftTarget: Float = 0
  private var counter = 0
  private var noise: NoiseGenerator

  /// maxDelaySeconds には、この揺れの最大の遅れ（baseDelay + 振れ幅の合計）より長い値を使う
  public var maxDelaySeconds: Double { Double(base + depths.reduce(0, +) + driftDepth) / sampleRate + 0.001 }
  private let sampleRate: Double

  public init(baseDelay: Double, wobbles: [Wobble], drift: Double = 0, sampleRate: Double, seed: UInt32 = 0x5EED) {
    self.sampleRate = sampleRate
    base = Float(baseDelay * sampleRate)
    depths = wobbles.map { Float($0.depth * sampleRate) }
    steps = wobbles.map { 2 * Double.pi * $0.frequency / sampleRate }
    phases = wobbles.indices.map { Double($0) * 1.7 }
    driftDepth = Float(drift * sampleRate)
    // 不規則な揺れ：0.7 秒ごとに新しい目標を選び、そこへゆっくり近づく
    driftInterval = Int(0.7 * sampleRate)
    driftSmoothing = Float(1 - exp(-1 / (0.5 * sampleRate)))
    noise = NoiseGenerator(seed: seed)
  }

  @inline(__always)
  public mutating func next() -> Float {
    var delay = base + drift
    for i in phases.indices {
      delay += depths[i] * Float(sin(phases[i]))
      phases[i] += steps[i]
      if phases[i] > 2 * Double.pi { phases[i] -= 2 * Double.pi }
    }
    counter += 1
    if counter >= driftInterval {
      counter = 0
      driftTarget = driftDepth * noise.next()
    }
    drift += driftSmoothing * (driftTarget - drift)
    return delay
  }

  public mutating func reset() {
    drift = 0
    driftTarget = 0
    counter = 0
  }
}

/// レコードの針や空電の「パチッ」。ランダムな時刻に始まり、すぐ消える雑音の粒
public struct Crackle {
  private let probability: Float
  private let amplitude: ClosedRange<Float>
  private let skew: Float
  private let decay: Float
  private var envelope: Float = 0
  private var noise: NoiseGenerator
  private var trigger: NoiseGenerator

  /// rate は 1 秒あたりの平均回数、decayMs は粒の長さ（63% 小さくなるまで）。
  /// skew を大きくすると小さい粒ばかりになり、大きい粒はたまにしか出ない（本物のほこりの音に近い）
  public init(rate: Double, amplitude: ClosedRange<Float>, skew: Float = 1, decayMs: Double, sampleRate: Double, seed: UInt32) {
    probability = Float(rate / sampleRate)
    self.amplitude = amplitude
    self.skew = skew
    decay = Float(exp(-1 / (decayMs * 0.001 * sampleRate)))
    noise = NoiseGenerator(seed: seed)
    trigger = NoiseGenerator(seed: seed ^ 0xA5A5_A5A5)
  }

  @inline(__always)
  public mutating func next() -> Float {
    if (trigger.next() + 1) / 2 < probability {
      let r = pow((noise.next() + 1) / 2, skew)
      envelope = amplitude.lowerBound + r * (amplitude.upperBound - amplitude.lowerBound)
    }
    let y = envelope * noise.next()
    envelope *= decay
    return y
  }

  public mutating func reset() {
    envelope = 0
  }
}

/// 盤の傷。1 回転ごとに同じ位置で「プツッ」と鳴る。大きさは毎回少しだけ変わる
public struct RevolutionClick {
  private let period: Int
  private let amplitude: Float
  private let decay: Float
  private var counter: Int
  private var envelope: Float = 0
  private var noise: NoiseGenerator

  /// revolutionsPerMinute：33⅓ なら 1.8 秒、78 なら 0.77 秒ごと。offset は最初の 1 回までの割合（0〜1）
  public init(revolutionsPerMinute: Double, amplitude: Float, decayMs: Double, offset: Double = 0.4, sampleRate: Double, seed: UInt32) {
    period = Int(60 / revolutionsPerMinute * sampleRate)
    self.amplitude = amplitude
    decay = Float(exp(-1 / (decayMs * 0.001 * sampleRate)))
    counter = Int(Double(period) * offset)
    noise = NoiseGenerator(seed: seed)
  }

  @inline(__always)
  public mutating func next() -> Float {
    counter += 1
    if counter >= period {
      counter = 0
      envelope = amplitude * (0.75 + 0.25 * noise.next())
    }
    let y = envelope * noise.next()
    envelope *= decay
    return y
  }

  public mutating func reset() {
    envelope = 0
  }
}

/// 盤が 1 回転するごとに、盤面の雑音が「シュッ、シュッ」と少し大きくなったり小さくなったりする揺れ（盤の反りや汚れのむら）
public struct RevolutionSwish {
  private var phase: Double = 0
  private let step: Double
  private let depth: Float

  public init(revolutionsPerMinute: Double, depth: Float, sampleRate: Double) {
    step = 2 * Double.pi * revolutionsPerMinute / 60 / sampleRate
    self.depth = depth
  }

  /// 雑音にかける倍率（1 ± depth）
  @inline(__always)
  public mutating func next() -> Float {
    phase += step
    if phase > 2 * Double.pi { phase -= 2 * Double.pi }
    // 正弦波を 2 乗して、1 回転のうち一部だけが強くなる形にする
    let s = Float(sin(phase))
    return 1 - depth + 2 * depth * s * s
  }
}
