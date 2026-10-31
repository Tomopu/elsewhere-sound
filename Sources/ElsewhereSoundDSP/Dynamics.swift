import Foundation

/// 音量の大きいところを抑えるコンプレッサー。ステレオは左右の大きい方で判定して、同じ量だけ下げる
public struct Compressor {
  public var thresholdDB: Float
  public var ratio: Float
  public var kneeDB: Float
  public var makeupDB: Float
  private let attack: Float
  private let release: Float
  /// いま下げている量（dB、正の値）
  private var reductionDB: Float = 0

  public init(
    thresholdDB: Float, ratio: Float, attackMs: Double, releaseMs: Double,
    kneeDB: Float = 6, makeupDB: Float = 0, sampleRate: Double
  ) {
    self.thresholdDB = thresholdDB
    self.ratio = ratio
    self.kneeDB = kneeDB
    self.makeupDB = makeupDB
    attack = Self.coefficient(ms: attackMs, sampleRate: sampleRate)
    release = Self.coefficient(ms: releaseMs, sampleRate: sampleRate)
  }

  /// 時定数 ms で目標に 63% 近づく 1 次の平滑化の係数
  private static func coefficient(ms: Double, sampleRate: Double) -> Float {
    Float(exp(-1 / (ms * 0.001 * sampleRate)))
  }

  /// level（振幅の絶対値）に対して掛ける倍率
  @inline(__always)
  public mutating func gain(level: Float) -> Float {
    let levelDB = 20 * log10(max(level, 1e-6))
    let target = staticReduction(levelDB)
    // 大きくなるときは attack、戻るときは release の速さで追う
    let coef = target > reductionDB ? attack : release
    reductionDB = target + coef * (reductionDB - target)
    return pow(10, (makeupDB - reductionDB) / 20)
  }

  /// ソフトニー付きの入出力特性で、levelDB のときに下げる量
  private func staticReduction(_ levelDB: Float) -> Float {
    let over = levelDB - thresholdDB
    let slope = 1 - 1 / ratio
    if over <= -kneeDB / 2 { return 0 }
    if over >= kneeDB / 2 { return slope * over }
    let x = over + kneeDB / 2
    return slope * x * x / (2 * kneeDB)
  }

  public mutating func reset() {
    reductionDB = 0
  }
}

/// 歪み。小さい音はそのまま、大きい音ほど丸く潰れる
@inline(__always)
public func saturate(_ x: Float, drive: Float) -> Float {
  tanh(drive * x) / tanh(drive)
}

/// オーディオスレッドで使える軽い乱数（xorshift32）。毎回同じ並びになるので、テストでも結果が揺れない
public struct NoiseGenerator {
  private var state: UInt32

  public init(seed: UInt32 = 0x9E37_79B9) {
    state = seed == 0 ? 1 : seed
  }

  /// -1...1 の一様乱数
  @inline(__always)
  public mutating func next() -> Float {
    state ^= state << 13
    state ^= state >> 17
    state ^= state << 5
    return Float(state) / Float(UInt32.max) * 2 - 1
  }
}
