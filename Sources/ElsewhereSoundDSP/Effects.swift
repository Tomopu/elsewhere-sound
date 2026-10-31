import Foundation

/// プリセット 1 つ分の加工。オーディオスレッドから呼ぶので、render の中では確保もロックもしない。
/// 中身は種類ごとに分けてある：響く場所（`RoomEffects`）、ラジオと電話（`RadioEffects`）、古い録音（`RecordingEffects`）
protocol Effect: AnyObject {
  /// 入力から、加工した音（原音を混ぜる前）だけを作る
  func render(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>,
    wetLeft: UnsafeMutablePointer<Float>, wetRight: UnsafeMutablePointer<Float>, frames: Int)
  /// 強さ amount（0...1）のときの、原音と加工した音の混ぜ方
  func mix(amount: Float) -> (dry: Float, wet: Float)
  func reset()
}

extension Effect {
  /// 原音を加工した音に置き換えていく（ラジオや古い録音など、場所の響きではないもの）
  func mix(amount: Float) -> (dry: Float, wet: Float) {
    (1 - amount, amount)
  }
}

extension Preset {
  func makeEffect(sampleRate sr: Double) -> Effect {
    switch self {
    case .hall:
      RoomEffect(.concertHall, airCutoff: 10000, dryLoss: 0.35, wetGain: 0.9, sampleRate: sr)
    case .cathedral:
      RoomEffect(.cathedral, airCutoff: 10000, dryLoss: 0.45, wetGain: 1.0, sampleRate: sr)
    case .jazzClub:
      // 狭い部屋は低音がこもって厚くなる
      RoomEffect(.jazzClub, airCutoff: 7000, bassBoostDB: 4, dryLoss: 0.25, wetGain: 0.6, sampleRate: sr)
    case .stadium:
      // ステージから遠いので直接音は小さく、届く響きは高音が少し落ちている。
      // ただし周りの歓声まで遠くならないよう、直接音は減らしすぎず、響きの高音も残す
      RoomEffect(.stadium, airCutoff: 8000, lowCut: 90, dryLoss: 0.35, wetGain: 1.0, sampleRate: sr)
    case .cinema: CinemaEffect(sampleRate: sr)
    case .nextRoom: ThroughWallEffect(sampleRate: sr)
    case .fmRadio: FMRadioEffect(sampleRate: sr)
    case .amRadio: AMRadioEffect(sampleRate: sr)
    case .telephone: TelephoneEffect(sampleRate: sr)
    case .vinyl: VinylEffect(sampleRate: sr)
    case .cassette: CassetteEffect(sampleRate: sr)
    case .gramophone: GramophoneEffect(sampleRate: sr)
    }
  }
}
