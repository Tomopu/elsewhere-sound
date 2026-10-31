import Testing

@testable import ElsewhereSoundDSP

@Suite("FFT による畳み込み")
struct ConvolverTests {
  /// 素朴に 1 サンプルずつ掛けて足す畳み込み（答え合わせ用）
  private func directConvolution(_ x: [Float], _ h: [Float]) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    for n in x.indices {
      for k in h.indices where k <= n {
        y[n] += x[n - k] * h[k]
      }
    }
    return y
  }

  @Test("インパルスを入れると、blockSize 遅れてインパルス応答そのものが出てくる")
  func impulseReturnsImpulseResponse() {
    var noise = NoiseGenerator(seed: 7)
    let h = (0..<300).map { _ in noise.next() }
    let convolver = PartitionedConvolver(impulse: h, blockSize: 64)
    let output = (0..<(64 + 400)).map { convolver.process($0 == 0 ? 1 : 0) }
    for k in h.indices {
      #expect(abs(output[64 + k] - h[k]) < 1e-4)
    }
    #expect(output[..<64].allSatisfy { $0 == 0 })
  }

  @Test("任意の入力で、直接計算した畳み込みと一致する", arguments: [16, 64, 256])
  func matchesDirectConvolution(blockSize: Int) {
    var noise = NoiseGenerator(seed: 42)
    let h = (0..<1000).map { _ in noise.next() * 0.1 }
    let x = (0..<3000).map { _ in noise.next() }
    let expected = directConvolution(x, h)
    let convolver = PartitionedConvolver(impulse: h, blockSize: blockSize)
    let output = x.map { convolver.process($0) } + (0..<blockSize).map { _ in convolver.process(0) }
    let worst = x.indices.map { abs(output[$0 + blockSize] - expected[$0]) }.max()!
    #expect(worst < 1e-4)
  }

  @Test("reset すると前の音の響きが残らない")
  func resetClearsTail() {
    let convolver = PartitionedConvolver(impulse: [Float](repeating: 0.1, count: 500), blockSize: 32)
    for _ in 0..<200 { _ = convolver.process(1) }
    convolver.reset()
    let output = (0..<600).map { _ in convolver.process(0) }
    #expect(output.allSatisfy { $0 == 0 })
  }
}
