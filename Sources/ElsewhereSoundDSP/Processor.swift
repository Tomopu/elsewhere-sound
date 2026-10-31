import Foundation
import Synchronization

/// 並びは画面に出す順。rawValue は設定に保存する番号なので、追加したものは後ろの番号にする
public enum Preset: Int, CaseIterable, Identifiable, Sendable {
  case hall = 0
  case cathedral = 3
  case jazzClub = 4
  case stadium = 5
  case cinema = 11
  case nextRoom = 6
  case fmRadio = 1
  case amRadio = 2
  case telephone = 7
  case vinyl = 8
  case cassette = 9
  case gramophone = 10

  public enum Group: CaseIterable, Sendable {
    case place
    case broadcast
    case recording

    public var title: String {
      switch self {
      case .place: "響く場所"
      case .broadcast: "ラジオ・電話"
      case .recording: "古い録音"
      }
    }

    public var presets: [Preset] { Preset.allCases.filter { $0.group == self } }
  }

  public var id: Int { rawValue }

  public var group: Group {
    switch self {
    case .hall, .cathedral, .jazzClub, .stadium, .cinema, .nextRoom: .place
    case .fmRadio, .amRadio, .telephone: .broadcast
    case .vinyl, .cassette, .gramophone: .recording
    }
  }

  public var title: String {
    switch self {
    case .hall: "コンサートホール"
    case .cathedral: "大聖堂・教会"
    case .jazzClub: "ジャズクラブ"
    case .stadium: "野外ライブ・スタジアム"
    case .cinema: "映画館"
    case .nextRoom: "隣の部屋"
    case .fmRadio: "FM ラジオ"
    case .amRadio: "AM ラジオ"
    case .telephone: "電話・トランシーバー"
    case .vinyl: "レコード"
    case .cassette: "カセットテープ"
    case .gramophone: "蓄音機（SP 盤）"
    }
  }

  /// コマンドラインで指定するときの名前
  public var key: String {
    switch self {
    case .hall: "hall"
    case .cathedral: "cathedral"
    case .jazzClub: "jazz"
    case .stadium: "stadium"
    case .cinema: "cinema"
    case .nextRoom: "nextroom"
    case .fmRadio: "fm"
    case .amRadio: "am"
    case .telephone: "phone"
    case .vinyl: "vinyl"
    case .cassette: "cassette"
    case .gramophone: "gramophone"
    }
  }

  /// 場所の響きは強さで客席の位置が変わる（前の席 ↔ 後ろの席）。それ以外は原音を置き換えていく
  public var placesListener: Bool {
    switch self {
    case .hall, .cathedral, .jazzClub, .stadium: true
    default: false
    }
  }

  /// 初めて使うときの強さ。場所の響きは中ほどの席（スタジアムは実況の声が埋もれない席）、それ以外はそのままの音
  public var defaultAmount: Double {
    switch self {
    case .stadium: 0.64
    default: placesListener ? 0.5 : 1
    }
  }
}

/// 音の加工の入口。画面（メインスレッド）からはプリセットと強さを変え、オーディオスレッドからは process を呼ぶ。
/// 2 つのスレッドの受け渡しは Atomic だけで行い、オーディオスレッドを待たせない。
public final class Processor: @unchecked Sendable {
  public let sampleRate: Double
  /// process はこの長さずつ区切って処理する（作業用の配列をこの長さで先に確保しておく）
  static let chunkSize = 1024

  private let effects: [Effect]
  private let requestedPreset: Atomic<Int>
  private let requestedAmount: Atomic<UInt32>
  private let inputPeakBits = Atomic<UInt32>(0)
  private let outputPeakBits = Atomic<UInt32>(0)
  private let repairedSamples = Atomic<Int>(0)
  private let recoveries = Atomic<Int>(0)
  /// 取り込んだ音をこの大きさで頭打ちにする。ふつうの音は ±1 に収まるので、少しはみ出すくらいはそのまま通す
  static let inputLimit: Float = 4

  // ここから下はオーディオスレッドだけが触る
  private var current: Int
  /// プリセットを切り替えた直後は、前のプリセットから 50 ms かけて音を入れ替える（プツッと鳴らないように）
  private var previous: Int?
  private var fadePosition = 0
  private let fadeLength: Int
  private var amount: Float
  private let amountSmoothing: Float
  private var limiter: Compressor
  private let wetA: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)
  private let wetB: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)

  public init(sampleRate: Double, preset: Preset = .hall, amount: Double = 0.5) {
    self.sampleRate = sampleRate
    // rawValue の番号で引けるように並べる
    let byNumber = Preset.allCases.sorted { $0.rawValue < $1.rawValue }
    precondition(byNumber.map(\.rawValue) == Array(byNumber.indices), "Preset の番号は 0 から隙間なく振る")
    effects = byNumber.map { $0.makeEffect(sampleRate: sampleRate) }
    requestedPreset = Atomic(preset.rawValue)
    requestedAmount = Atomic(Float(amount).bitPattern)
    current = preset.rawValue
    self.amount = Float(amount)
    fadeLength = Int(0.05 * sampleRate)
    amountSmoothing = Float(1 - exp(-1 / (0.03 * sampleRate)))
    // 最後の安全装置。響きを足して 0 dB を超えそうなときだけ働く
    limiter = Compressor(thresholdDB: -1.5, ratio: 20, attackMs: 1, releaseMs: 80, kneeDB: 2, sampleRate: sampleRate)
    func buffer() -> UnsafeMutablePointer<Float> {
      let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkSize)
      p.initialize(repeating: 0, count: Self.chunkSize)
      return p
    }
    wetA = (buffer(), buffer())
    wetB = (buffer(), buffer())
  }

  deinit {
    for p in [wetA.0, wetA.1, wetB.0, wetB.1] {
      p.deallocate()
    }
  }

  // MARK: - 画面から

  public var preset: Preset {
    get { Preset(rawValue: requestedPreset.load(ordering: .relaxed))! }
    set { requestedPreset.store(newValue.rawValue, ordering: .relaxed) }
  }

  public var strength: Double {
    get { Double(Float(bitPattern: requestedAmount.load(ordering: .relaxed))) }
    set { requestedAmount.store(Float(min(max(newValue, 0), 1)).bitPattern, ordering: .relaxed) }
  }

  /// 前回呼んでからの入力と出力の最大振幅。呼ぶと 0 に戻る
  public func takePeaks() -> (input: Float, output: Float) {
    (Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed)),
     Float(bitPattern: outputPeakBits.exchange(0, ordering: .relaxed)))
  }

  /// 前回呼んでからの、入力の壊れた値（NaN・無限大・極端に大きい値）を直した数と、
  /// 加工の途中で値が壊れて全部の状態を消した回数。呼ぶと 0 に戻る
  public func takeRepairs() -> (samples: Int, recoveries: Int) {
    (repairedSamples.exchange(0, ordering: .relaxed), recoveries.exchange(0, ordering: .relaxed))
  }

  // MARK: - オーディオスレッドから

  /// 左右の音をその場で書き換える
  public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
    var offset = 0
    while offset < frames {
      let count = min(Self.chunkSize, frames - offset)
      processChunk(left: left + offset, right: right + offset, frames: count)
      offset += count
    }
  }

  private func processChunk(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
    let requested = requestedPreset.load(ordering: .relaxed)
    if requested != current {
      previous = current
      current = requested
      fadePosition = 0
      // しばらく使っていなかったプリセットには古い響きが残っているので消してから使う
      effects[current].reset()
    }
    let targetAmount = Float(bitPattern: requestedAmount.load(ordering: .relaxed))

    // NaN や無限大が 1 つでもフィルタ・響き・リミッターに入ると、その中にずっと残って二度と音が戻らない。
    // 動画を飛ばしたときなどに取り込んだ音に混ざることがあるので、加工する前に直しておく
    var repaired = 0
    for i in 0..<frames where !(abs(left[i]) <= Self.inputLimit && abs(right[i]) <= Self.inputLimit) {
      left[i] = Self.repaired(left[i])
      right[i] = Self.repaired(right[i])
      repaired += 1
    }
    if repaired > 0 { repairedSamples.add(repaired, ordering: .relaxed) }

    effects[current].render(left: left, right: right, wetLeft: wetA.0, wetRight: wetA.1, frames: frames)
    if let previous {
      effects[previous].render(left: left, right: right, wetLeft: wetB.0, wetRight: wetB.1, frames: frames)
    }

    var inputPeak: Float = 0
    var outputPeak: Float = 0
    var broken = false
    for i in 0..<frames {
      let dryL = left[i], dryR = right[i]
      inputPeak = max(inputPeak, abs(dryL), abs(dryR))
      amount += amountSmoothing * (targetAmount - amount)

      let gains = effects[current].mix(amount: amount)
      var l = dryL * gains.dry + wetA.0[i] * gains.wet
      var r = dryR * gains.dry + wetA.1[i] * gains.wet
      if let previous {
        let old = effects[previous].mix(amount: amount)
        // 区切りの途中で入れ替えが終わっても、その区切りの終わりまでは新しい音だけを使う
        let t = min(1, Float(fadePosition) / Float(fadeLength))
        l = t * l + (1 - t) * (dryL * old.dry + wetB.0[i] * old.wet)
        r = t * r + (1 - t) * (dryR * old.dry + wetB.1[i] * old.wet)
        fadePosition += 1
        if fadePosition >= fadeLength { self.previous = nil }
      }

      let g = limiter.gain(level: max(abs(l), abs(r)))
      l = min(max(l * g, -1), 1)
      r = min(max(r * g, -1), 1)
      left[i] = l
      right[i] = r
      broken = broken || !(l.isFinite && r.isFinite)
      outputPeak = max(outputPeak, abs(l), abs(r))
    }

    // 入力を直しても加工の途中で値が壊れたときは、壊れた値を残さないよう全部の状態を消して、この区切りは無音にする
    if broken {
      effects[current].reset()
      if let previous { effects[previous].reset() }
      previous = nil
      limiter.reset()
      amount = targetAmount
      left.update(repeating: 0, count: frames)
      right.update(repeating: 0, count: frames)
      outputPeak = 0
      recoveries.add(1, ordering: .relaxed)
    }

    // 画面が読みに来るまでの最大値を残す（読み取りと重なって 1 回分取りこぼしても困らない）
    let storedIn = Float(bitPattern: inputPeakBits.load(ordering: .relaxed))
    inputPeakBits.store(max(storedIn, inputPeak).bitPattern, ordering: .relaxed)
    let storedOut = Float(bitPattern: outputPeakBits.load(ordering: .relaxed))
    outputPeakBits.store(max(storedOut, outputPeak).bitPattern, ordering: .relaxed)
  }

  /// NaN は 0 に、大きすぎる値（無限大を含む）は ±inputLimit にする
  @inline(__always)
  private static func repaired(_ x: Float) -> Float {
    x.isNaN ? 0 : min(max(x, -inputLimit), inputLimit)
  }
}
