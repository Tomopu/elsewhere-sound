import CoreAudio
import Foundation

/// Core Audio の失敗。どの操作で失敗したかと OSStatus を持つ
struct CoreAudioError: LocalizedError {
  let operation: String
  let status: OSStatus

  var errorDescription: String? {
    "\(operation)に失敗しました（OSStatus \(status)）"
  }
}

func check(_ status: OSStatus, _ operation: String) throws {
  guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
}

extension AudioObjectID {
  static let system = AudioObjectID(kAudioObjectSystemObject)

  /// 固定長の値（デバイス ID、サンプルレート、フォーマットなど）を読む
  func read<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &value) {
      AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0.baseAddress!)
    }
    try check(status, "Core Audio のプロパティの読み取り")
    return value
  }

  func readString(_ selector: AudioObjectPropertySelector) throws -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Core Audio の文字列の読み取り")
    guard let value else { throw CoreAudioError(operation: "Core Audio の文字列の読み取り", status: kAudioHardwareUnspecifiedError) }
    return value.takeRetainedValue() as String
  }

  /// いまの出力先（スピーカーやヘッドホン）
  static func defaultOutputDevice() throws -> AudioObjectID {
    try system.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
  }

  /// プロセス ID から Core Audio のプロセスオブジェクトを引く
  static func process(pid: pid_t) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var pid = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
      AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
      "プロセスの検索")
    guard object != kAudioObjectUnknown else {
      throw CoreAudioError(operation: "自分のプロセスの検索", status: kAudioHardwareBadObjectError)
    }
    return object
  }
}
