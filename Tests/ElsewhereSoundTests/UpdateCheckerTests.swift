import Foundation
import Testing

@testable import ElsewhereSound

@Suite("アップデートの確認")
struct UpdateCheckerTests {
  @Test("版は数字ごとに比べる（10 は 9 より新しい、足りない桁は 0）")
  func versionOrder() {
    #expect(AppVersion("0.2.0") > AppVersion("0.1.0"))
    #expect(AppVersion("0.10.0") > AppVersion("0.9.3"))
    #expect(AppVersion("1.0") > AppVersion("0.99.99"))
    #expect(AppVersion("1.2") == AppVersion("1.2.0"))
    #expect(!(AppVersion("0.1.0") > AppVersion("0.1.0")))
    #expect(AppVersion("1.0.0-beta") == AppVersion("1.0.0"))
  }

  @Test("GitHub の最新リリースの JSON から、v を除いた版とページを取り出す")
  func parsesRelease() throws {
    let json = #"{"tag_name": "v0.2.0", "html_url": "https://github.com/Tomopu/elsewhere-sound/releases/tag/v0.2.0", "draft": false}"#
    let release = try UpdateChecker.parseRelease(Data(json.utf8))
    #expect(release.version == "0.2.0")
    #expect(release.page.absoluteString == "https://github.com/Tomopu/elsewhere-sound/releases/tag/v0.2.0")
  }

  @Test("形の違う返事は、読めなかったという失敗にする")
  func rejectsUnexpectedJSON() {
    #expect(throws: UpdateChecker.CheckError.self) {
      try UpdateChecker.parseRelease(Data(#"{"message": "Not Found"}"#.utf8))
    }
  }
}
