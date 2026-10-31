import Foundation

/// 響く場所の客席で聞く音。原音（直接音）に、計算で作った部屋の響きを畳み込んで足す
final class RoomEffect: Effect {
  private let convolvers: (left: PartitionedConvolver, right: PartitionedConvolver)
  /// 響きの音色。客席に届く響きは、空気と客席に高い音を吸われて丸くなっている
  private var tone: [BiquadCascade]
  private let dryLoss: Float
  private let wetGain: Float

  /// dryLoss：強さ 1 で直接音をどれだけ減らすか。wetGain：強さ 1 での響きの大きさ
  init(
    _ room: RoomImpulse, airCutoff: Double, bassBoostDB: Double = 0, lowCut: Double? = nil,
    dryLoss: Float, wetGain: Float, sampleRate: Double
  ) {
    let blockSize = 512
    var room = room
    // 畳み込み自体が blockSize だけ遅れるので、その分を響きの始まりの遅れから引いておく
    room.preDelay = max(0, room.preDelay - Double(blockSize) / sampleRate)
    let ir = room.generate(sampleRate: sampleRate)
    convolvers = (PartitionedConvolver(impulse: ir.left, blockSize: blockSize),
                  PartitionedConvolver(impulse: ir.right, blockSize: blockSize))

    var stages: [Biquad] = [
      .lowPass(airCutoff, sampleRate: sampleRate),
      // 響きには 300 Hz あたりがたまりやすく、原音の中音〜高音（声や歓声）を覆ってしまうので少し削る
      .peaking(300, q: 0.8, gainDB: -2.5, sampleRate: sampleRate),
    ]
    if bassBoostDB != 0 { stages.append(.lowShelf(150, gainDB: bassBoostDB, sampleRate: sampleRate)) }
    if let lowCut { stages.append(.highPass(lowCut, sampleRate: sampleRate)) }
    tone = [BiquadCascade(stages), BiquadCascade(stages)]
    self.dryLoss = dryLoss
    self.wetGain = wetGain
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      wetLeft[i] = tone[0].process(convolvers.left.process(left[i]))
      wetRight[i] = tone[1].process(convolvers.right.process(right[i]))
    }
  }

  /// 強くするほど後ろの席に下がる：直接音が小さくなり、響きが大きくなる
  func mix(amount: Float) -> (dry: Float, wet: Float) {
    (1 - dryLoss * amount, wetGain * amount)
  }

  func reset() {
    convolvers.left.reset()
    convolvers.right.reset()
    tone[0].reset()
    tone[1].reset()
  }
}

/// 隣の部屋で鳴っている音を、壁越しに聞く。
/// 隣の部屋の響きごと、壁を通り抜けた音になる。壁は重いほど高い音を通さない（質量則）ので低音ばかりが届き、
/// 壁と部屋の共鳴で 100 Hz あたりがふくらむ。左右の区別もほとんどなくなる
final class ThroughWallEffect: Effect {
  private let convolvers: (left: PartitionedConvolver, right: PartitionedConvolver)
  private var wall: [BiquadCascade]

  init(sampleRate sr: Double) {
    let ir = RoomImpulse.livingRoom.generate(sampleRate: sr)
    convolvers = (PartitionedConvolver(impulse: ir.left, blockSize: 256),
                  PartitionedConvolver(impulse: ir.right, blockSize: 256))
    let stages: [Biquad] = [
      .lowPass(380, sampleRate: sr), .lowPass(380, sampleRate: sr), .lowPass(900, sampleRate: sr),
      .peaking(110, q: 1.4, gainDB: 6, sampleRate: sr),
      .highPass(35, sampleRate: sr),
    ]
    wall = [BiquadCascade(stages), BiquadCascade(stages)]
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      // 隣の部屋の中の音：直接音と部屋の響き
      let roomL = 0.7 * left[i] + 0.6 * convolvers.left.process(left[i])
      let roomR = 0.7 * right[i] + 0.6 * convolvers.right.process(right[i])
      let center = 0.5 * (roomL + roomR)
      // 0.67 は原音より少しだけ小さく聞こえる倍率（壁越しなので）
      wetLeft[i] = 0.67 * wall[0].process(0.8 * center + 0.2 * roomL)
      wetRight[i] = 0.67 * wall[1].process(0.8 * center + 0.2 * roomR)
    }
  }

  func reset() {
    convolvers.left.reset()
    convolvers.right.reset()
    wall[0].reset()
    wall[1].reset()
  }
}

/// 映画館の客席。
/// - スクリーンの裏の大きなスピーカーと、サブウーファーの重い低音
/// - 横と後ろの壁のサラウンドスピーカーに包まれる広がり（左右の差の成分を、少し遅らせて広げて鳴らす）
/// - 吸音された広い部屋の短い響きと、スクリーン越しで少し落ち着いた高音
final class CinemaEffect: Effect {
  private let convolvers: (left: PartitionedConvolver, right: PartitionedConvolver)
  private var screen: [BiquadCascade]
  private var surroundTone: [BiquadCascade]
  private let surroundDelays: (ModulatedDelay, ModulatedDelay)
  private let surroundDelay: (Float, Float)

  init(sampleRate sr: Double) {
    let blockSize = 512
    var room = RoomImpulse.cinema
    room.preDelay = max(0, room.preDelay - Double(blockSize) / sr)
    let ir = room.generate(sampleRate: sr)
    convolvers = (PartitionedConvolver(impulse: ir.left, blockSize: blockSize),
                  PartitionedConvolver(impulse: ir.right, blockSize: blockSize))
    let screenStages: [Biquad] = [
      .highShelf(7000, gainDB: -2, sampleRate: sr),
      // サブウーファーの重い低音。低音だけを別に取り出して足すと位相がずれて打ち消し合うので、シェルフで持ち上げる
      .lowShelf(90, gainDB: 6, sampleRate: sr),
      .highPass(25, sampleRate: sr), .highPass(25, sampleRate: sr),
    ]
    screen = [BiquadCascade(screenStages), BiquadCascade(screenStages)]
    let surroundStages: [Biquad] = [.highPass(150, sampleRate: sr), .lowPass(7000, sampleRate: sr)]
    surroundTone = [BiquadCascade(surroundStages), BiquadCascade(surroundStages)]
    surroundDelays = (ModulatedDelay(maxDelaySeconds: 0.03, sampleRate: sr), ModulatedDelay(maxDelaySeconds: 0.03, sampleRate: sr))
    // 左右のサラウンドは距離が違うので、届く時間を少しずらす
    surroundDelay = (Float(0.017 * sr), Float(0.023 * sr))
  }

  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int
  ) {
    for i in 0..<frames {
      let l = left[i], r = right[i]
      let side = 0.5 * (l - r)
      let surroundL = surroundTone[0].process(surroundDelays.0.process(side, delay: surroundDelay.0))
      let surroundR = surroundTone[1].process(surroundDelays.1.process(-side, delay: surroundDelay.1))
      let roomL = convolvers.left.process(l)
      let roomR = convolvers.right.process(r)
      // 0.8 は原音とだいたい同じ音量になる倍率（低音とサラウンドを足した分を下げる）
      wetLeft[i] = 0.8 * (screen[0].process(l) + 0.6 * surroundL + 0.3 * roomL)
      wetRight[i] = 0.8 * (screen[1].process(r) + 0.6 * surroundR + 0.3 * roomR)
    }
  }

  func reset() {
    convolvers.left.reset()
    convolvers.right.reset()
    for i in 0..<2 {
      screen[i].reset()
      surroundTone[i].reset()
    }
    surroundDelays.0.reset()
    surroundDelays.1.reset()
  }
}
