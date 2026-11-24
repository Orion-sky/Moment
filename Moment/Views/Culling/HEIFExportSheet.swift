import SwiftUI
import Combine

/// 筛选模式「转换为 HEIF…」的弹窗:选保存位置和画质
struct HEIFExportSheet: View {
    @EnvironmentObject var store: ImageStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("heifQuality") private var quality = 0.85
    @State private var destination: URL?

    var body: some View {
        let count = store.picked.count
        let rawCount = store.picked.count(where: ImageMeta.isRAW)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("转换为 HEIF").font(.headline)
                Text("将标记的 \(count) 张照片转换为 HEIF,原文件保持不变。")
                    .foregroundStyle(.secondary)
            }

            Form {
                LabeledContent("保存到") {
                    HStack {
                        Text(destination?.path ?? "未选择")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(destination == nil ? .secondary : .primary)
                            .help(destination?.path ?? "")
                        Spacer(minLength: 8)
                        Button("选择…") {
                            if let url = store.chooseHEIFFolder(startingAt: destination) { destination = url }
                        }
                    }
                }

                LabeledContent("画质") {
                    HStack {
                        Slider(value: $quality, in: 0.5...1, step: 0.05)
                        Text("\(Int((quality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .formStyle(.columns)

            VStack(alignment: .leading, spacing: 4) {
                Text(qualityHint)
                if rawCount > 0 {
                    Text("RAW 会直接从原始数据转换,保存为 10 位色深,不经过 JPEG。")
                }
                Text("拍摄参数会完整保留;保存位置已有同名文件时自动改名,不会覆盖。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("转换") {
                    guard let destination else { return }
                    let quality = quality
                    dismiss()
                    // 弹窗关掉之后再开始,进度显示在筛选操作条上
                    DispatchQueue.main.async { store.convertPickedToHEIF(to: destination, quality: quality) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil || count == 0)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { destination = store.lastHEIFFolder }
    }

    private var qualityHint: String {
        switch quality {
        case 0.9...: "画质很高,和原图几乎看不出差别,文件也较大。"
        case 0.8..<0.9: "推荐:肉眼基本看不出差别,体积通常能小一半左右。"
        case 0.7..<0.8: "体积更小,放大细看时细节会略少。"
        default: "体积很小,细节和渐变会有明显损失。"
        }
    }
}
