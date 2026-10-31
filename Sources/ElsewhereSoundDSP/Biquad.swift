import Foundation

/// 2 次の IIR フィルタ。係数は RBJ の Audio EQ Cookbook の式
public struct Biquad {
  private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
  private var z1: Float = 0, z2: Float = 0

  private init(b: (Double, Double, Double), a: (Double, Double, Double)) {
    b0 = Float(b.0 / a.0)
    b1 = Float(b.1 / a.0)
    b2 = Float(b.2 / a.0)
    a1 = Float(a.1 / a.0)
    a2 = Float(a.2 / a.0)
  }

  /// Q = 1/√2 で 2 段重ねると Linkwitz–Riley（4 次）になる
  public static let butterworthQ = 1 / 2.0.squareRoot()

  public static func lowPass(_ frequency: Double, q: Double = butterworthQ, sampleRate: Double) -> Biquad {
    let (cosw, alpha) = terms(frequency, q, sampleRate)
    return Biquad(
      b: ((1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2),
      a: (1 + alpha, -2 * cosw, 1 - alpha))
  }

  public static func highPass(_ frequency: Double, q: Double = butterworthQ, sampleRate: Double) -> Biquad {
    let (cosw, alpha) = terms(frequency, q, sampleRate)
    return Biquad(
      b: ((1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2),
      a: (1 + alpha, -2 * cosw, 1 - alpha))
  }

  /// 山型（gainDB が負なら谷型）のイコライザ
  public static func peaking(_ frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
    let (cosw, alpha) = terms(frequency, q, sampleRate)
    let a = pow(10, gainDB / 40)
    return Biquad(
      b: (1 + alpha * a, -2 * cosw, 1 - alpha * a),
      a: (1 + alpha / a, -2 * cosw, 1 - alpha / a))
  }

  /// frequency より上を gainDB だけ持ち上げる（下げる）。傾きは S = 1
  public static func highShelf(_ frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
    let a = pow(10, gainDB / 40)
    let (cosw, alpha) = terms(frequency, butterworthQ, sampleRate)
    let k = 2 * a.squareRoot() * alpha
    return Biquad(
      b: (a * ((a + 1) + (a - 1) * cosw + k), -2 * a * ((a - 1) + (a + 1) * cosw), a * ((a + 1) + (a - 1) * cosw - k)),
      a: ((a + 1) - (a - 1) * cosw + k, 2 * ((a - 1) - (a + 1) * cosw), (a + 1) - (a - 1) * cosw - k))
  }

  /// frequency より下を gainDB だけ持ち上げる（下げる）。傾きは S = 1
  public static func lowShelf(_ frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
    let a = pow(10, gainDB / 40)
    let (cosw, alpha) = terms(frequency, butterworthQ, sampleRate)
    let k = 2 * a.squareRoot() * alpha
    return Biquad(
      b: (a * ((a + 1) - (a - 1) * cosw + k), 2 * a * ((a - 1) - (a + 1) * cosw), a * ((a + 1) - (a - 1) * cosw - k)),
      a: ((a + 1) + (a - 1) * cosw + k, -2 * ((a - 1) + (a + 1) * cosw), (a + 1) + (a - 1) * cosw - k))
  }

  private static func terms(_ frequency: Double, _ q: Double, _ sampleRate: Double) -> (cosw: Double, alpha: Double) {
    // ナイキスト周波数に近すぎると係数が壊れるので手前で止める
    let w = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
    return (cos(w), sin(w) / (2 * q))
  }

  /// 転置直接形 II
  @inline(__always)
  public mutating func process(_ x: Float) -> Float {
    let y = b0 * x + z1
    z1 = b1 * x - a1 * y + z2
    z2 = b2 * x - a2 * y
    return y
  }

  public mutating func reset() {
    z1 = 0
    z2 = 0
  }
}

/// 同じ種類のフィルタを何段か重ねたもの。段数を増やすほど切れ味が鋭くなる
public struct BiquadCascade {
  private var stages: [Biquad]

  public init(_ stages: [Biquad]) {
    self.stages = stages
  }

  public init(repeating stage: Biquad, count: Int) {
    stages = Array(repeating: stage, count: count)
  }

  @inline(__always)
  public mutating func process(_ x: Float) -> Float {
    var y = x
    for i in stages.indices {
      y = stages[i].process(y)
    }
    return y
  }

  public mutating func reset() {
    for i in stages.indices {
      stages[i].reset()
    }
  }
}
