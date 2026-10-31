import Foundation
import Testing

@testable import ElsewhereSoundDSP

private let sampleRate = 48_000.0

/// frequency Hz の正弦波 seconds 秒
private func sine(_ frequency: Double, seconds: Double, amplitude: Float = 0.3) -> [Float] {
  (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

/// x に含まれる frequency Hz の成分の大きさ（Goertzel 法）
private func magnitude(_ x: [Float], _ frequency: Double) -> Float {
  let w = 2 * Double.pi * frequency / sampleRate
  var s1 = 0.0, s2 = 0.0
  for v in x {
    let s0 = Double(v) + 2 * cos(w) * s1 - s2
    s2 = s1
    s1 = s0
  }
  return Float((s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2).squareRoot() / Double(x.count))
}

private func rms(_ x: ArraySlice<Float>) -> Float {
  (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

/// processor に左右同じ音 input を通して、左右の出力を返す
private func run(_ processor: Processor, _ input: [Float]) -> (left: [Float], right: [Float]) {
  var left = input
  var right = input
  left.withUnsafeMutableBufferPointer { l in
    right.withUnsafeMutableBufferPointer { r in
      // 実際のオーディオスレッドと同じく、半端な長さに区切って渡す
      var offset = 0
      while offset < input.count {
        let n = min(441, input.count - offset)
        processor.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: n)
        offset += n
      }
    }
  }
  return (left, right)
}

@Suite("フィルタ")
struct FilterTests {
  @Test("1 kHz のローパスは 8 kHz を 30 dB 以上下げ、200 Hz はほぼそのまま通す")
  func lowPassAttenuatesHighs() {
    func gain(_ frequency: Double) -> Float {
      var filter = BiquadCascade(repeating: .lowPass(1000, sampleRate: sampleRate), count: 2)
      let x = sine(frequency, seconds: 0.5)
      let y = x.map { filter.process($0) }
      return rms(y[12000...]) / rms(x[12000...])
    }
    #expect(gain(8000) < 0.03)
    #expect(abs(gain(200) - 1) < 0.05)
  }

  @Test("コンプレッサーは閾値を超えた分を ratio 分の 1 にする")
  func compressorRatio() {
    var compressor = Compressor(thresholdDB: -20, ratio: 4, attackMs: 1, releaseMs: 10, kneeDB: 0, sampleRate: sampleRate)
    var g: Float = 1
    // -8 dB（閾値より 12 dB 上）を入れ続けると、出力は閾値より 3 dB 上になる
    let level = pow(10, Float(-8) / 20)
    for _ in 0..<4800 { g = compressor.gain(level: level) }
    #expect(abs(20 * log10(level * g) - -17) < 0.1)
  }
}

@Suite("プリセット")
struct PresetTests {
  @Test("AM ラジオは 6 kHz の音をほとんど通さず、左右が同じ音になる")
  func amRadioIsNarrowAndMono() {
    let processor = Processor(sampleRate: sampleRate, preset: .amRadio, amount: 1)
    let high = run(processor, sine(6000, seconds: 1))
    let mid = run(Processor(sampleRate: sampleRate, preset: .amRadio, amount: 1), sine(1000, seconds: 1))
    #expect(rms(high.left[24000...]) < 0.1 * rms(mid.left[24000...]))
    #expect(mid.left == mid.right)
  }

  @Test("FM ラジオは 17 kHz を大きく下げ、1 kHz は通す")
  func fmRadioCutsAbove15k() {
    let high = run(Processor(sampleRate: sampleRate, preset: .fmRadio, amount: 1), sine(17000, seconds: 1))
    let mid = run(Processor(sampleRate: sampleRate, preset: .fmRadio, amount: 1), sine(1000, seconds: 1))
    #expect(rms(high.left[24000...]) < 0.15 * rms(mid.left[24000...]))
  }

  @Test("ホールは音が止まったあとも響きが続き、およそ 2 秒で消える")
  func hallHasReverbTail() {
    let input = sine(500, seconds: 0.5) + [Float](repeating: 0, count: Int(3 * sampleRate))
    let output = run(Processor(sampleRate: sampleRate, preset: .hall, amount: 1), input).left
    let stop = Int(0.5 * sampleRate)
    let tail = rms(output[(stop + 2400)..<(stop + 7200)])
    let late = rms(output[(stop + Int(2.6 * sampleRate))...])
    #expect(tail > 0.01)
    #expect(late < tail * 0.01)
  }

  @Test("強さ 0 なら原音がそのまま出る", arguments: Preset.allCases)
  func zeroAmountIsTransparent(preset: Preset) {
    let input = sine(440, seconds: 0.3)
    let output = run(Processor(sampleRate: sampleRate, preset: preset, amount: 0), input).left
    let worst = zip(input, output).map { abs($0 - $1) }.max()!
    #expect(worst < 1e-5)
  }

  @Test("再生中にプリセットを切り替えても、大きな段差やおかしな値が出ない")
  func switchingPresetsIsSmooth() {
    let processor = Processor(sampleRate: sampleRate, preset: .hall, amount: 0.8)
    var input = sine(220, seconds: 2)
    input = input.indices.map { input[$0] * (0.5 + 0.5 * Float($0 % 9000) / 9000) }
    var left = input
    var right = input
    var jumps: [Float] = []
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        for (k, offset) in stride(from: 0, to: input.count, by: 512).enumerated() {
          if k % 20 == 19 { processor.preset = Preset.allCases[(k / 20) % 3] }
          processor.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: min(512, input.count - offset))
        }
      }
    }
    for i in 1..<left.count { jumps.append(abs(left[i] - left[i - 1])) }
    #expect(left.allSatisfy { $0.isFinite && abs($0) <= 1 })
    #expect(jumps.max()! < 0.5)
  }
}

@Suite("追加したプリセット")
struct MorePresetTests {
  /// 1 秒の音を入れてから 7 秒の無音を続け、音が止まった時点からの出力を返す
  private func tailAfterStop(_ preset: Preset) -> (output: [Float], stop: Int) {
    let input = sine(500, seconds: 1) + [Float](repeating: 0, count: Int(7 * sampleRate))
    return (run(Processor(sampleRate: sampleRate, preset: preset, amount: 1), input).left, Int(sampleRate))
  }

  @Test("どのプリセットも音を入れれば音が出て、おかしな値や大きすぎる音は出ない", arguments: Preset.allCases)
  func everyPresetIsSane(preset: Preset) {
    // 低い音・中くらいの音・高い音を重ねた和音
    let input = zip(zip(sine(110, seconds: 1), sine(880, seconds: 1)), sine(5000, seconds: 1, amplitude: 0.1)).map { $0.0 + $0.1 + $1 }
    let output = run(Processor(sampleRate: sampleRate, preset: preset, amount: 1), input)
    #expect(output.left.allSatisfy { $0.isFinite && abs($0) <= 1 })
    let ratio = rms(output.left[12000...]) / rms(input[12000...])
    #expect(ratio > 0.2 && ratio < 3)
  }

  @Test("大聖堂の響きは 4 秒たってもまだ残るが、コンサートホールは消えている")
  func cathedralRingsLongerThanHall() {
    let cathedral = tailAfterStop(.cathedral)
    let hall = tailAfterStop(.hall)
    let window = (cathedral.stop + Int(4 * sampleRate))..<(cathedral.stop + Int(4.5 * sampleRate))
    #expect(rms(cathedral.output[window]) > 10 * rms(hall.output[window]))
    #expect(rms(cathedral.output[window]) > 1e-4)
  }

  @Test("ジャズクラブの響きは 1 秒で消える")
  func jazzClubIsShort() {
    let jazz = tailAfterStop(.jazzClub)
    let early = rms(jazz.output[(jazz.stop + 1200)..<(jazz.stop + 4800)])
    let late = rms(jazz.output[(jazz.stop + Int(1.2 * sampleRate))..<(jazz.stop + Int(1.5 * sampleRate))])
    #expect(late < early * 0.01)
  }

  @Test("スタジアムのインパルス応答には、0.33 秒あたりにはっきりしたやまびこがある")
  func stadiumHasEcho() {
    let room = RoomImpulse.stadium
    let ir = room.generate(sampleRate: sampleRate).left
    func index(_ seconds: Double) -> Int { Int((room.preDelay + seconds) * sampleRate) }
    let echoPeak = ir[index(0.325)..<index(0.34)].map(abs).max()!
    let around = ir[index(0.25)..<index(0.31)].map(abs).max()!
    #expect(echoPeak > 3 * around)
  }

  @Test("隣の部屋は 2 kHz をほとんど通さず、低い音は通す")
  func nextRoomPassesOnlyBass() {
    let high = run(Processor(sampleRate: sampleRate, preset: .nextRoom, amount: 1), sine(2000, seconds: 1))
    let low = run(Processor(sampleRate: sampleRate, preset: .nextRoom, amount: 1), sine(110, seconds: 1))
    #expect(rms(high.left[24000...]) < 0.03 * rms(low.left[24000...]))
  }

  @Test("電話は 150 Hz と 6 kHz をほとんど通さない")
  func telephoneIsNarrow() {
    // 単音を別々に入れるとコンプレッサーが小さい音を持ち上げてしまうので、和音にして同じ条件で比べる
    let chord = zip(zip(sine(150, seconds: 1), sine(1000, seconds: 1)), sine(6000, seconds: 1)).map { $0.0 + $0.1 + $1 }
    let output = Array(run(Processor(sampleRate: sampleRate, preset: .telephone, amount: 1), chord).left[24000...])
    let voice = magnitude(output, 1000)
    #expect(magnitude(output, 150) < 0.15 * voice)
    #expect(magnitude(output, 6000) < 0.15 * voice)
  }

  @Test("蓄音機は 100 Hz と 8 kHz をほとんど通さない")
  func gramophoneIsNarrow() {
    func level(_ frequency: Double) -> Float {
      rms(run(Processor(sampleRate: sampleRate, preset: .gramophone, amount: 1), sine(frequency, seconds: 1, amplitude: 0.1)).left[24000...])
    }
    let mid = level(1500)
    #expect(level(100) < 0.2 * mid)
    #expect(level(8000) < 0.2 * mid)
  }

  @Test("蓄音機は無音でも針音が大きく鳴り、部屋の響きで左右が少しずつ違う")
  func gramophoneHasNoiseAndRoom() {
    let output = run(Processor(sampleRate: sampleRate, preset: .gramophone, amount: 1), [Float](repeating: 0, count: Int(3 * sampleRate)))
    let l = output.left[24000...], r = output.right[24000...]
    #expect(rms(l) > 0.005)
    let correlation = zip(l, r).reduce(0) { $0 + $1.0 * $1.1 } / (rms(l) * rms(r) * Float(l.count))
    #expect(correlation > 0.3 && correlation < 0.95)
  }

  @Test("レコードは無音でも針音が鳴り、低音の左右の差はカッティングでなくなる")
  func vinylHasCrackleAndMonoBass() {
    let silent = run(Processor(sampleRate: sampleRate, preset: .vinyl, amount: 1), [Float](repeating: 0, count: Int(3 * sampleRate)))
    #expect(silent.left[24000...].map(abs).max()! > 0.01)
    // 左右逆向きの 60 Hz（左右の差だけの低音）はほとんど消える。1 kHz なら残る
    func sideLevel(_ frequency: Double) -> Float {
      var left = sine(frequency, seconds: 1)
      var right = left.map { -$0 }
      let processor = Processor(sampleRate: sampleRate, preset: .vinyl, amount: 1)
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          processor.process(left: l.baseAddress!, right: r.baseAddress!, frames: l.count)
        }
      }
      // 回転むらで音程がわずかに揺れるので、周波数成分ではなく差の信号全体の大きさで比べる
      return rms(ArraySlice(zip(left[24000...], right[24000...]).map { ($0 - $1) / 2 }))
    }
    #expect(sideLevel(60) < 0.4 * sideLevel(1000))
  }

  @Test("映画館は低音が厚い（50 Hz が 1 kHz より大きく持ち上がる）")
  func cinemaHasHeavyBass() {
    func gain(_ frequency: Double) -> Float {
      let input = sine(frequency, seconds: 1, amplitude: 0.1)
      return rms(run(Processor(sampleRate: sampleRate, preset: .cinema, amount: 1), input).left[24000...]) / rms(input[24000...])
    }
    #expect(gain(50) > 1.5 * gain(1000))
  }
}

@Suite("回転むらと雑音の部品")
struct TextureTests {
  @Test("遅れを一定にすると、入力がそのサンプル数だけ遅れて出てくる")
  func constantDelayShiftsSignal() {
    let delay = ModulatedDelay(maxDelaySeconds: 0.01, sampleRate: sampleRate)
    var noise = NoiseGenerator(seed: 3)
    let input = (0..<2000).map { _ in noise.next() }
    let output = input.map { delay.process($0, delay: 37) }
    for i in 37..<input.count {
      #expect(output[i] == input[i - 37])
    }
  }

  @Test("回転むらの遅れは、決めた幅の中で揺れる")
  func wowStaysWithinRange() {
    var wow = WowFlutter(
      baseDelay: 0.004, wobbles: [.init(frequency: 0.9, depth: 0.0005), .init(frequency: 5, depth: 0.00003)],
      drift: 0.0003, sampleRate: sampleRate)
    let delays = (0..<Int(10 * sampleRate)).map { _ in wow.next() }
    let limit = Float(wow.maxDelaySeconds * sampleRate)
    #expect(delays.min()! > 0)
    #expect(delays.max()! < limit)
    // 実際に揺れている（0.9 Hz の揺れの幅 ±24 サンプルのうち、大半は使っている）
    #expect(delays.max()! - delays.min()! > 30)
  }

  @Test("パチパチは平均してだいたい決めた回数だけ起きる")
  func crackleRate() {
    var crackle = Crackle(rate: 20, amplitude: 0.5...0.5, decayMs: 0.05, sampleRate: sampleRate, seed: 11)
    // 粒は 0.01 未満の静かな時間が 100 サンプル続いたあとに、0.01 を超えたら 1 回と数える
    var events = 0
    var quietRun = 100
    for _ in 0..<Int(10 * sampleRate) {
      if abs(crackle.next()) > 0.01 {
        if quietRun >= 100 { events += 1 }
        quietRun = 0
      } else {
        quietRun += 1
      }
    }
    #expect((150...250).contains(events))
  }

  @Test("盤の傷は 1 回転に 1 回ずつ鳴る（78 回転なら 10 秒で 13 回）")
  func revolutionClickRepeats() {
    var click = RevolutionClick(revolutionsPerMinute: 78, amplitude: 0.5, decayMs: 0.3, sampleRate: sampleRate, seed: 5)
    var events = 0
    var quietRun = 100
    for _ in 0..<Int(10 * sampleRate) {
      if abs(click.next()) > 0.05 {
        if quietRun >= 100 { events += 1 }
        quietRun = 0
      } else {
        quietRun += 1
      }
    }
    #expect(events == 13)
  }
}

@Suite("壊れた入力から立ち直る")
struct RecoveryTests {
  @Test("1 サンプルだけ NaN や無限大が来ても、そのあとの音はまた普通に出る", arguments: Preset.allCases, [Float.nan, .infinity])
  func recoversFromNonFiniteInput(preset: Preset, bad: Float) {
    let processor = Processor(sampleRate: sampleRate, preset: preset, amount: 1)
    // 隣の部屋は低音だけ、電話は中音だけを通すので、両方を混ぜておく
    var input = zip(sine(200, seconds: 3, amplitude: 0.2), sine(1000, seconds: 3, amplitude: 0.2)).map(+)
    input[Int(0.5 * sampleRate)] = bad
    let out = run(processor, input)
    // 響きの尾が消えたあと（2 秒より後）は、どの値も有限で、音も出ている
    let tail = out.left[Int(2 * sampleRate)...] + out.right[Int(2 * sampleRate)...]
    let finite = tail.allSatisfy { $0.isFinite }
    #expect(finite)
    #expect(rms(tail) > 0.01)
  }
}
