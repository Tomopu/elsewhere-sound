import CoreAudio
import Foundation
import ElsewhereSoundDSP

/// Mac から出る音を横取りして加工し、スピーカーへ出し直す。
///
/// 1. Process Tap で、このアプリ以外の全プロセスの音をステレオで受け取る。
///    受け取っている間は元の音を鳴らさない（mutedWhenTapped。アプリが落ちれば元の音に戻る）
/// 2. その Tap と、いまの出力先をまとめた非公開の集約デバイスを作る
/// 3. 集約デバイスの IOProc では、入力に Tap の音、出力にスピーカー行きのバッファが同時に来るので、
///    その場で Processor に通して書き込む。間にバッファを挟まないので、遅れは IO 1 回分で済む
/// このアプリが鳴らす音は Tap から外してあるので、加工した音をまた拾って回り続けることはない。
final class SystemAudioTap {
  private(set) var processor: Processor?
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "ElsewhereSound.audio", qos: .userInteractive)
  /// IOProc で左右の音を並べ直すための作業場所（オーディオスレッドで確保しないよう先に用意する）
  private let maxFrames = 8192
  private let scratch: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)

  var isRunning: Bool { ioProcID != nil }

  init() {
    scratch = (.allocate(capacity: maxFrames), .allocate(capacity: maxFrames))
  }

  deinit {
    stop()
    scratch.0.deallocate()
    scratch.1.deallocate()
  }

  /// 出力先が変わったら、いったん stop してから呼び直す
  func start(preset: Preset, amount: Double) throws {
    stop()
    do {
      try createTap()
      let sampleRate = try createAggregateDevice()
      let processor = Processor(sampleRate: sampleRate, preset: preset, amount: amount)
      self.processor = processor
      try check(
        AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [unowned self] _, input, _, output, _ in
          render(input: input, output: output, processor: processor)
        }, "音声処理の登録")
      try check(AudioDeviceStart(aggregateID, ioProcID), "音声処理の開始")
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    if let ioProcID {
      AudioDeviceStop(aggregateID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
      self.ioProcID = nil
    }
    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
    processor = nil
  }

  private var tapUUID = UUID()

  private func createTap() throws {
    let ownProcess = try AudioObjectID.process(pid: getpid())
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
    tapUUID = UUID()
    description.uuid = tapUUID
    description.name = "Elsewhere Sound"
    description.isPrivate = true
    description.muteBehavior = .mutedWhenTapped
    try check(AudioHardwareCreateProcessTap(description, &tapID), "システム音声の取り込みの準備")

    let format = try tapID.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
    guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
      throw CoreAudioError(operation: "取り込んだ音の形式（32 bit 浮動小数点ではない）の確認", status: kAudioHardwareUnsupportedOperationError)
    }
  }

  /// Tap と出力先をまとめた集約デバイスを作り、そのサンプルレートを返す
  private func createAggregateDevice() throws -> Double {
    let outputUID = try AudioObjectID.defaultOutputDevice().readString(kAudioDevicePropertyDeviceUID)
    let description: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Elsewhere Sound",
      kAudioAggregateDeviceUIDKey: "com.tomopu.ElsewhereSound.aggregate.\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      // 他のアプリのデバイス一覧には出さない
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString],
      ],
    ]
    try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "出力用のデバイスの作成")
    return try aggregateID.read(kAudioDevicePropertyNominalSampleRate, initial: Float64(48_000))
  }

  // MARK: - オーディオスレッド

  private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, processor: Processor) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputs {
      if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }

    // 入力には出力先のデバイスのマイクなどが先に並ぶことがあり、Tap のステレオは最後の 2 チャンネルに来る
    let inputChannels = inputs.reduce(0) { $0 + Int($1.mNumberChannels) }
    guard inputChannels > 0,
          let left = channel(inputs, max(0, inputChannels - 2)),
          let right = channel(inputs, inputChannels - 1)
    else { return }
    let frames = min(maxFrames, left.frames)
    for i in 0..<frames {
      scratch.0[i] = left.data[i * left.stride]
      scratch.1[i] = right.data[i * right.stride]
    }

    processor.process(left: scratch.0, right: scratch.1, frames: frames)

    let outputChannels = outputs.reduce(0) { $0 + Int($1.mNumberChannels) }
    if outputChannels == 1, let mono = channel(outputs, 0) {
      for i in 0..<min(frames, mono.frames) {
        mono.data[i * mono.stride] = 0.5 * (scratch.0[i] + scratch.1[i])
      }
      return
    }
    // 3 チャンネル以上ある出力先（オーディオインターフェースなど）でも、鳴らすのは 1・2 チャンネル目だけ
    if let outLeft = channel(outputs, 0), let outRight = channel(outputs, 1) {
      for i in 0..<min(frames, outLeft.frames, outRight.frames) {
        outLeft.data[i * outLeft.stride] = scratch.0[i]
        outRight.data[i * outRight.stride] = scratch.1[i]
      }
    }
  }

  /// 全バッファを通して index 番目のチャンネルの先頭、サンプルの間隔、フレーム数。
  /// インターリーブ（1 つのバッファに LRLR…）でも、チャンネルごとの別バッファでも同じように扱う
  private func channel(_ buffers: UnsafeMutableAudioBufferListPointer, _ index: Int) -> (data: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
    var rest = index
    for buffer in buffers {
      let count = Int(buffer.mNumberChannels)
      if rest < count {
        guard let data = buffer.mData, count > 0 else { return nil }
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count)
        return (data.assumingMemoryBound(to: Float.self) + rest, count, frames)
      }
      rest -= count
    }
    return nil
  }
}
