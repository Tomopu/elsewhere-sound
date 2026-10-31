import AppKit
import Foundation

/// 「アップデートを確認」を押したときだけ、GitHub の最新リリースを問い合わせる。
/// 起動時や定期的には問い合わせない。新しい版があれば知らせて、ダウンロードページを開く
@MainActor
final class UpdateChecker: ObservableObject {
  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, page: URL)
    case failed(String)
  }

  @Published private(set) var state = State.idle
  /// このアプリの版（Info.plist の CFBundleShortVersionString）
  let currentVersion: String
  private let open: (URL) -> Void

  nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/Tomopu/ElsewhereSound/releases/latest")!
  nonisolated static let releasesPage = URL(string: "https://github.com/Tomopu/ElsewhereSound/releases")!

  init(
    currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
    open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
  ) {
    self.currentVersion = currentVersion
    self.open = open
  }

  var message: String? {
    switch state {
    case .idle: nil
    case .checking: "確認しています…"
    case .upToDate: "最新の版（\(currentVersion)）です"
    case .available(let version, _): "新しい版 \(version) があります（いまは \(currentVersion)）\nダウンロードページを開きました"
    case .failed(let reason): "確認できませんでした：\(reason)"
    }
  }

  func check() {
    guard state != .checking else { return }
    state = .checking
    Task {
      do {
        let release = try await Self.fetchLatestRelease()
        if AppVersion(release.version) > AppVersion(currentVersion) {
          state = .available(version: release.version, page: release.page)
          open(release.page)
        } else {
          state = .upToDate
        }
      } catch {
        state = .failed(error.localizedDescription)
      }
    }
  }

  #if DEBUG
    /// 開発用：パネルの撮影で、確認したあとの表示を出す
    func preview(_ state: State) { self.state = state }
  #endif

  /// 新しい版を見つけたあと、もう一度ダウンロードページを開く
  func openDownloadPage() {
    if case .available(_, let page) = state { open(page) } else { open(Self.releasesPage) }
  }

  struct Release: Equatable {
    var version: String
    var page: URL
  }

  struct CheckError: LocalizedError {
    let errorDescription: String?
  }

  private nonisolated static func fetchLatestRelease() async throws -> Release {
    var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    // Cookie やキャッシュを残さない
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      throw CheckError(errorDescription: status == 404 ? "公開されている版がまだありません" : "GitHub が \(status) を返しました")
    }
    return try parseRelease(data)
  }

  /// GitHub の releases/latest の JSON から、版（先頭の v を除いたタグ）とページの URL を取り出す
  nonisolated static func parseRelease(_ data: Data) throws -> Release {
    struct Body: Decodable {
      let tag_name: String
      let html_url: URL
    }
    guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
      throw CheckError(errorDescription: "GitHub の返事を読めませんでした")
    }
    let version = body.tag_name.hasPrefix("v") ? String(body.tag_name.dropFirst()) : body.tag_name
    return Release(version: version, page: body.html_url)
  }
}

/// 「1.2.3」のような版を数字ごとに比べる。足りない桁は 0（1.2 と 1.2.0 は同じ）。「-beta」などの後ろは見ない
struct AppVersion: Comparable {
  let parts: [Int]

  init(_ string: String) {
    let core = string.split(separator: "-", maxSplits: 1).first ?? ""
    parts = core.split(separator: ".").map { Int($0) ?? 0 }
  }

  static func < (a: AppVersion, b: AppVersion) -> Bool {
    for i in 0..<max(a.parts.count, b.parts.count) {
      let x = i < a.parts.count ? a.parts[i] : 0
      let y = i < b.parts.count ? b.parts[i] : 0
      if x != y { return x < y }
    }
    return false
  }

  static func == (a: AppVersion, b: AppVersion) -> Bool {
    !(a < b) && !(b < a)
  }
}
