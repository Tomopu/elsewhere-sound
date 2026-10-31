import Accelerate

/// 長いインパルス応答を、FFT で区切って畳み込む（一様分割の overlap-save）。
///
/// インパルス応答を blockSize ごとに P 個に切り、それぞれの周波数特性 H[p] を先に計算しておく。
/// 入力も blockSize ずつ FFT して直近 P 個を覚えておき、出力のブロックは
///   Y = Σ X[今から p 個前] × H[p]
/// を逆 FFT して作る。直接畳み込むと 1 サンプルあたり IR の長さ（10 万回以上）の掛け算が要るところを、
/// 1 ブロックあたり FFT 2 回と複素数の掛け算 P × blockSize 回で済ませる。
/// 出力は入力より blockSize サンプル遅れる。
public final class PartitionedConvolver {
  public let blockSize: Int
  private let fftSize: Int
  private let log2n: vDSP_Length
  private let setup: FFTSetup
  private let partitionCount: Int

  // 周波数領域の値は vDSP の実数 FFT の詰め方（実部・虚部を別配列、0 番の虚部にナイキスト成分）で持つ
  private let irReal: UnsafeMutablePointer<Float>
  private let irImag: UnsafeMutablePointer<Float>
  private let historyReal: UnsafeMutablePointer<Float>
  private let historyImag: UnsafeMutablePointer<Float>
  private let accReal: UnsafeMutablePointer<Float>
  private let accImag: UnsafeMutablePointer<Float>
  /// 直前のブロックと今のブロックを並べた、FFT にかける窓（fftSize）
  private let window: UnsafeMutablePointer<Float>
  private let inverse: UnsafeMutablePointer<Float>
  /// 前回のブロックから計算済みの出力（blockSize）
  private let output: UnsafeMutablePointer<Float>
  private var position = 0
  private var historyIndex = 0
  /// 順 FFT で 2 倍、逆 FFT で fftSize 倍になるので、X × H を戻すと 4 × fftSize 倍になっている
  private let scale: Float

  public init(impulse: [Float], blockSize: Int = 512) {
    precondition(blockSize.nonzeroBitCount == 1, "blockSize は 2 のべき乗")
    self.blockSize = blockSize
    fftSize = blockSize * 2
    log2n = vDSP_Length(fftSize.trailingZeroBitCount)
    setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    partitionCount = max(1, (impulse.count + blockSize - 1) / blockSize)
    scale = 1 / Float(4 * fftSize)

    let bins = partitionCount * blockSize
    func zeroed(_ count: Int) -> UnsafeMutablePointer<Float> {
      let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
      p.initialize(repeating: 0, count: count)
      return p
    }
    irReal = zeroed(bins)
    irImag = zeroed(bins)
    historyReal = zeroed(bins)
    historyImag = zeroed(bins)
    accReal = zeroed(blockSize)
    accImag = zeroed(blockSize)
    window = zeroed(fftSize)
    inverse = zeroed(fftSize)
    output = zeroed(blockSize)

    // インパルス応答の各区間を、後ろを 0 で埋めて fftSize にしてから FFT する
    for p in 0..<partitionCount {
      let start = p * blockSize
      let count = min(blockSize, impulse.count - start)
      window.update(repeating: 0, count: fftSize)
      impulse.withUnsafeBufferPointer { window.update(from: $0.baseAddress! + start, count: count) }
      forward(window, intoReal: irReal + start, imag: irImag + start)
    }
    window.update(repeating: 0, count: fftSize)
  }

  deinit {
    vDSP_destroy_fftsetup(setup)
    for p in [irReal, irImag, historyReal, historyImag, accReal, accImag, window, inverse, output] {
      p.deallocate()
    }
  }

  /// 1 サンプル入れて 1 サンプル取り出す。blockSize サンプルごとにまとめて計算する
  @inline(__always)
  public func process(_ x: Float) -> Float {
    window[blockSize + position] = x
    let y = output[position]
    position += 1
    if position == blockSize {
      convolveBlock()
      position = 0
    }
    return y
  }

  public func reset() {
    position = 0
    historyIndex = 0
    let bins = partitionCount * blockSize
    historyReal.update(repeating: 0, count: bins)
    historyImag.update(repeating: 0, count: bins)
    window.update(repeating: 0, count: fftSize)
    output.update(repeating: 0, count: blockSize)
  }

  private func forward(_ signal: UnsafeMutablePointer<Float>, intoReal real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
    var split = DSPSplitComplex(realp: real, imagp: imag)
    signal.withMemoryRebound(to: DSPComplex.self, capacity: blockSize) {
      vDSP_ctoz($0, 2, &split, 1, vDSP_Length(blockSize))
    }
    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
  }

  private func convolveBlock() {
    let n = vDSP_Length(blockSize)
    forward(window, intoReal: historyReal + historyIndex * blockSize, imag: historyImag + historyIndex * blockSize)

    accReal.update(repeating: 0, count: blockSize)
    accImag.update(repeating: 0, count: blockSize)
    var acc = DSPSplitComplex(realp: accReal, imagp: accImag)
    // 0 番は直流とナイキスト成分を詰めた特別な値なので、複素数の掛け算とは別に計算する
    var dc: Float = 0
    var nyquist: Float = 0
    for p in 0..<partitionCount {
      let h = p * blockSize
      let x = ((historyIndex - p + partitionCount) % partitionCount) * blockSize
      var xs = DSPSplitComplex(realp: historyReal + x, imagp: historyImag + x)
      var hs = DSPSplitComplex(realp: irReal + h, imagp: irImag + h)
      vDSP_zvma(&xs, 1, &hs, 1, &acc, 1, &acc, 1, n)
      dc += historyReal[x] * irReal[h]
      nyquist += historyImag[x] * irImag[h]
    }
    accReal[0] = dc
    accImag[0] = nyquist

    vDSP_fft_zrip(setup, &acc, 1, log2n, FFTDirection(FFT_INVERSE))
    inverse.withMemoryRebound(to: DSPComplex.self, capacity: blockSize) {
      vDSP_ztoc(&acc, 1, $0, 2, n)
    }
    // 窓の後半だけが正しい（巡回の回り込みがない）出力
    var s = scale
    vDSP_vsmul(inverse + blockSize, 1, &s, output, 1, n)

    // 今のブロックを窓の前半へずらして、次のブロックに備える
    window.update(from: window + blockSize, count: blockSize)
    historyIndex = (historyIndex + 1) % partitionCount
  }
}
