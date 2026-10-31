#if DEBUG
import AppKit
import ElsewhereSoundDSP
import SwiftUI

/// 開発用：`swift run ElsewhereSound --snapshot <出力先>` で操作パネルを PNG に描き出して終了する。
/// メニューバーのパネルは開かないと見えないので、同じ View を普通のウィンドウに置いて自分で描く
@MainActor
enum Snapshot {
  static func runIfRequested() {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
    let directory = URL(fileURLWithPath: arguments[index + 1])
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSApplication.shared.setActivationPolicy(.accessory)

    // 音声は動かさない。保存済みの設定も書き換えないよう、終わったら元に戻す
    let savedPreset = UserDefaults.standard.object(forKey: "preset")
    for (preset, appearance) in [(Preset.hall, NSAppearance.Name.aqua), (.cassette, .darkAqua)] {
      let controller = AudioController(autoStart: false)
      controller.preset = preset
      let suffix = appearance == .aqua ? "light" : "dark"
      // ダークの方には、新しい版を見つけたときの表示も出しておく
      let updates = UpdateChecker(currentVersion: "0.1.0", open: { _ in })
      if appearance == .darkAqua { updates.preview(.available(version: "0.2.0", page: UpdateChecker.releasesPage)) }
      render(ControlPanel(controller: controller, updates: updates), appearance: appearance, to: directory.appending(path: "panel-\(suffix).png"))
    }
    UserDefaults.standard.set(savedPreset, forKey: "preset")
    exit(0)
  }

  static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
    let host = NSHostingView(rootView: view.background(.windowBackground))
    let window = NSWindow(
      contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: host.fittingSize),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    defer { window.orderOut(nil) }
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
#endif
