import AVFoundation
import Foundation
import ElsewhereSoundDSP

/// 開発用：音声ファイルを Processor に通して書き出す。システム音声の取り込みなしで、加工だけを耳で確かめられる
enum FileRenderer {
  /// 引数は「プリセット 入力 出力 [強さ]」。プリセットは Preset.key の名前（hall・fm・vinyl など）
  static func run(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 3, let preset = Preset.allCases.first(where: { $0.key == arguments[0] }) else {
      let keys = Preset.allCases.map(\.key).joined(separator: "|")
      FileHandle.standardError.write(Data("使い方: ElsewhereSound --render \(keys) <入力> <出力.wav> [強さ 0〜1]\n".utf8))
      return 2
    }
    let amount = arguments.count > 3 ? Double(arguments[3]) ?? preset.defaultAmount : preset.defaultAmount
    do {
      let input = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[1]))
      let format = input.processingFormat
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else { return 1 }
      try input.read(into: buffer)

      // モノラルのファイルは左右に同じ音を入れて、ステレオで書き出す
      let frames = Int(buffer.frameLength)
      let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
      let result = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
      result.frameLength = AVAudioFrameCount(frames)
      let source = buffer.floatChannelData!
      let left = result.floatChannelData![0]
      let right = result.floatChannelData![1]
      left.update(from: source[0], count: frames)
      right.update(from: source[format.channelCount > 1 ? 1 : 0], count: frames)

      let processor = Processor(sampleRate: format.sampleRate, preset: preset, amount: amount)
      processor.process(left: left, right: right, frames: frames)

      // ファイルの中身はインターリーブにして、書き込むバッファの形式（左右別々）とは別に指定する
      var settings = stereo.settings
      settings[AVLinearPCMIsNonInterleaved] = false
      let output = try AVAudioFile(
        forWriting: URL(fileURLWithPath: arguments[2]), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
      try output.write(from: result)
      return 0
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      return 1
    }
  }
}
