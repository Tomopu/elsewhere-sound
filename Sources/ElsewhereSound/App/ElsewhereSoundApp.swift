import AppKit
import SwiftUI

@main
enum Main {
  static func main() {
    // 開発用：ファイルを変換して、音の加工だけを確かめる（`ElsewhereSound --render hall in.wav out.wav`）
    if let index = CommandLine.arguments.firstIndex(of: "--render") {
      exit(FileRenderer.run(Array(CommandLine.arguments[(index + 1)...])))
    }
    #if DEBUG
      MainActor.assumeIsolated { Snapshot.runIfRequested() }
    #endif
    ElsewhereSoundApp.main()
  }
}

/// メニューバーに常駐するだけのアプリ（Dock には出さない。Info.plist の LSUIElement）
struct ElsewhereSoundApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @StateObject private var controller = AudioController()

  var body: some Scene {
    MenuBarExtra {
      ControlPanel(controller: controller)
    } label: {
      Image(systemName: controller.isOn ? controller.preset.symbol : "hifispeaker")
    }
    .menuBarExtraStyle(.window)
  }
}

/// アプリランチャーや Finder から開いたとき、メニューバーのアイコンだけでは開いたことに気づきにくいので、パネルを開いて見せる
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // メニューバーのアイコンができるのを待つ
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.openPanel() }
  }

  /// 動いている最中にもう一度開いたとき
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    Self.openPanel()
    return false
  }

  /// MenuBarExtra にはパネルを開く API がないので、メニューバーのアイコンのボタンを探して押す
  @MainActor
  private static func openPanel() {
    let statusWindows = NSApp.windows.filter { $0.className == "NSStatusBarWindow" }
    // もう開いているなら押さない（押すと閉じてしまう）
    guard !NSApp.windows.contains(where: { $0.isVisible && !statusWindows.contains($0) }) else { return }
    for window in statusWindows {
      if let button = window.contentView.flatMap(statusButton(in:)) {
        button.performClick(nil)
        return
      }
    }
  }

  private static func statusButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    return view.subviews.lazy.compactMap(statusButton(in:)).first
  }
}
