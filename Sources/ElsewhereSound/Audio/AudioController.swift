import CoreAudio
import Foundation
import ElsewhereSoundDSP
import os

/// 画面とオーディオの橋渡し。オン・オフ、プリセット、強さを持ち、出力先が変わったら作り直す
@MainActor
final class AudioController: ObservableObject {
  @Published private(set) var isOn = false
  @Published private(set) var errorMessage: String?
  @Published var preset: Preset {
    didSet {
      UserDefaults.standard.set(preset.rawValue, forKey: "preset")
      tap.processor?.preset = preset
      amount = Self.savedAmount(for: preset)
    }
  }
  /// 強さはプリセットごとに覚えておく
  @Published var amount: Double {
    didSet {
      UserDefaults.standard.set(amount, forKey: Self.amountKey(preset))
      tap.processor?.strength = amount
    }
  }
  /// 0...1 に直した音量（-60 dB が 0、0 dB が 1）
  @Published private(set) var inputLevel: Double = 0
  @Published private(set) var outputLevel: Double = 0
  /// オンにしてから入力がずっと無音の秒数。許可がないと Tap は無音を返すので、その案内に使う
  @Published private(set) var silentSeconds: Double = 0

  private let tap = SystemAudioTap()
  private var meterTimer: Timer?

  /// autoStart：前回オンのまま終了していたら、すぐオンにする（開発用の撮影では動かさない）
  init(autoStart: Bool = true) {
    let preset = Preset(rawValue: UserDefaults.standard.integer(forKey: "preset")) ?? .hall
    self.preset = preset
    amount = Self.savedAmount(for: preset)
    watchDefaultOutput()
    if autoStart && UserDefaults.standard.bool(forKey: "isOn") {
      setOn(true)
    }
  }

  private static func amountKey(_ preset: Preset) -> String { "amount.\(preset.rawValue)" }

  private static func savedAmount(for preset: Preset) -> Double {
    UserDefaults.standard.object(forKey: amountKey(preset)) as? Double ?? preset.defaultAmount
  }

  func setOn(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: "isOn")
    if on {
      do {
        try tap.start(preset: preset, amount: amount)
        errorMessage = nil
        isOn = true
        silentSeconds = 0
        startMeter()
        log("開始：\(Int(tap.processor?.sampleRate ?? 0)) Hz、\(preset.title)、強さ \(amount)")
      } catch {
        errorMessage = error.localizedDescription
        isOn = false
        log("開始できませんでした：\(error.localizedDescription)")
      }
    } else {
      tap.stop()
      isOn = false
      meterTimer?.invalidate()
      meterTimer = nil
      inputLevel = 0
      outputLevel = 0
    }
  }

  private func startMeter() {
    meterTimer?.invalidate()
    let interval = 1.0 / 15
    meterTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let peaks = self.tap.processor?.takePeaks() else { return }
        // 上がるときはすぐ、下がるときはゆっくり
        self.inputLevel = max(Self.meterValue(peaks.input), self.inputLevel * 0.85)
        self.outputLevel = max(Self.meterValue(peaks.output), self.outputLevel * 0.85)
        self.silentSeconds = peaks.input == 0 ? self.silentSeconds + interval : 0
        if Self.logsLevels {
          self.log(String(format: "入力 %.4f 出力 %.4f", peaks.input, peaks.output))
        }
        if let repairs = self.tap.processor?.takeRepairs(), repairs.samples > 0 || repairs.recoveries > 0 {
          self.log("壊れた値を直しました：入力 \(repairs.samples) サンプル、加工のやり直し \(repairs.recoveries) 回")
        }
      }
    }
  }

  /// 開発用：ELSEWHERE_LOG_LEVELS=1 で起動すると、入出力の最大振幅を標準出力に書く
  private static let logsLevels = ProcessInfo.processInfo.environment["ELSEWHERE_LOG_LEVELS"] == "1"
  /// ランチャーから開いたときは標準出力が見えないので、macOS のログにも書く
  /// （`log show --predicate 'subsystem == "com.tomopu.ElsewhereSound"' --last 1h` で読める）
  private static let logger = Logger(subsystem: "com.tomopu.ElsewhereSound", category: "audio")

  private func log(_ message: String) {
    print("[ElsewhereSound] \(message)")
    fflush(stdout)
    Self.logger.notice("\(message, privacy: .public)")
  }

  private static func meterValue(_ peak: Float) -> Double {
    guard peak > 0 else { return 0 }
    return min(max((20 * log10(Double(peak)) + 60) / 60, 0), 1)
  }

  /// ヘッドホンを挿したときなど、出力先が変わったら新しい出力先で作り直す
  private func watchDefaultOutput() {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(.system, &address, .main) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self, self.isOn else { return }
        self.setOn(true)
      }
    }
  }
}
