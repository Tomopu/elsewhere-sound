import ElsewhereSoundDSP
import SwiftUI

extension Preset {
  var symbol: String {
    switch self {
    case .hall: "building.columns"
    case .cathedral: "bell"
    case .jazzClub: "pianokeys"
    case .stadium: "sportscourt"
    case .cinema: "popcorn"
    case .nextRoom: "door.left.hand.closed"
    case .fmRadio: "radio"
    case .amRadio: "antenna.radiowaves.left.and.right"
    case .telephone: "phone"
    case .vinyl: "opticaldisc"
    case .cassette: "recordingtape"
    case .gramophone: "megaphone"
    }
  }

  /// タイルに収まる名前。正式な名前（title）はパネル下の説明に出す
  var shortTitle: String {
    switch self {
    case .stadium: "スタジアム"
    case .telephone: "電話・無線"
    default: title
    }
  }

  var subtitle: String {
    switch self {
    case .hall: "客席で聞く響き（残響 約 2 秒）"
    case .cathedral: "石造りの空間。高音まで 6 秒ほど響く"
    case .jazzClub: "近くて短い響き（約 0.8 秒）と厚い低音"
    case .stadium: "薄く広い響きと、向かいのスタンドからのやまびこ"
    case .cinema: "重い低音と、周りから包まれる広がり"
    case .nextRoom: "壁越しにこもった、低音ばかりの音"
    case .fmRadio: "放送局の音圧と 15 kHz までの帯域"
    case .amRadio: "モノラル・狭い帯域・雑音"
    case .telephone: "300 Hz〜3.4 kHz と、デジタル圧縮のザラつき"
    case .vinyl: "針のパチパチ、回転の揺れ、丸い高音"
    case .cassette: "ヒスノイズ、揺れ、テープの飽和、こもった高音"
    case .gramophone: "狭い帯域、ジリジリ・ブツブツの針音、ラッパの響き"
    }
  }

  var strengthLabel: String {
    placesListener ? "響きの量（前の席 ↔ 後ろの席）" : "効果の強さ"
  }
}

/// メニューバーのアイコンを押すと開くパネル
struct ControlPanel: View {
  @ObservedObject var controller: AudioController

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Elsewhere Sound").font(.headline)
        Spacer()
        Toggle("効果をかける", isOn: Binding(get: { controller.isOn }, set: { controller.setOn($0) }))
          .toggleStyle(.switch)
          .labelsHidden()
      }

      ForEach(Preset.Group.allCases, id: \.self) { group in
        VStack(alignment: .leading, spacing: 4) {
          Text(group.title).font(.caption).foregroundStyle(.secondary)
          LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
            ForEach(group.presets) { preset in
              PresetTile(preset: preset, isSelected: controller.preset == preset) {
                controller.preset = preset
              }
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        (Text(controller.preset.title).bold().foregroundStyle(.primary) + Text("　") + Text(controller.preset.subtitle))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Text(controller.preset.strengthLabel)
          Spacer()
          Text("\(Int((controller.amount * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.top, 4)
        Slider(value: $controller.amount, in: 0...1)
      }

      VStack(spacing: 6) {
        LevelMeter(label: "入力", level: controller.inputLevel)
        LevelMeter(label: "出力", level: controller.outputLevel)
      }

      if let message = controller.errorMessage {
        Text(message).font(.caption).foregroundStyle(.red)
      } else if controller.isOn && controller.silentSeconds > 4 {
        Text("入力が無音です。再生中なのに無音なら、システム設定 →「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で Elsewhere Sound を許可してください。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
      HStack {
        Text(controller.isOn ? "Mac から出る音すべてに効果をかけています" : "オフ：元の音のまま")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("終了") { NSApplication.shared.terminate(nil) }
      }
    }
    .padding(16)
    .frame(width: 340)
  }
}

private struct PresetTile: View {
  let preset: Preset
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: preset.symbol)
          .frame(width: 20)
          .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        Text(preset.shortTitle)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.callout)
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
      .background(
        isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
        in: RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
  }
}

private struct LevelMeter: View {
  let label: String
  /// 0...1
  let level: Double

  var body: some View {
    HStack(spacing: 8) {
      Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.quaternary)
          Capsule()
            .fill(level > 0.95 ? Color.red : Color.green)
            .frame(width: geometry.size.width * level)
        }
      }
      .frame(height: 6)
    }
  }
}
