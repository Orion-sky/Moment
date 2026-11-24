import SwiftUI
import Combine

/// 筛选模式的操作条:浮在照片区域顶部
struct CullingBar: View {
    @EnvironmentObject var store: ImageStore
    @AppStorage("cullingIncludeRAW") private var includePairs = false
    @State private var confirmingDelete = false
    @State private var convertingToHEIF = false

    var body: some View {
        let count = store.picked.count
        let pairs = store.pickedPairs
        let withPairs = includePairs && !pairs.isEmpty
        let pairsText = ImageStore.describe(pairs, of: store.picked)
        HStack(spacing: 6) {
            if let transfer = store.transfer {
                ProgressView(value: Double(transfer.done), total: Double(max(transfer.total, 1)))
                    .frame(width: 160)
                Text("正在\(transfer.verb) \(transfer.done) / \(transfer.total)")
                    .monospacedDigit()
            } else {
                Text(count == 0 ? "按 \(ShortcutStore.displayName(ShortcutStore.shared.key(for: .togglePick))) 标记照片"
                                : "已标记 \(count) 张")
                    .monospacedDigit()
                    .foregroundStyle(count == 0 ? .secondary : .primary)

                Divider().frame(height: 16)

                Button("全选") { store.pickAll() }
                Button("反选") { store.invertPicks() }
                Button("清除") { store.clearPicks() }
                    .disabled(count == 0)

                if !pairs.isEmpty {
                    Divider().frame(height: 16)
                    Toggle("连同 \(pairsText)", isOn: $includePairs)
                        .toggleStyle(.checkbox)
                        // 鼠标停在上面可以看到具体会带上哪些文件
                        .help("复制 / 移动 / 删除时会带上这些还没标记的同名文件:\n"
                              + pairs.map(\.lastPathComponent).sorted().prefix(12).joined(separator: "\n")
                              + (pairs.count > 12 ? "\n…共 \(pairs.count) 个" : ""))
                }

                Divider().frame(height: 16)

                Button("复制到…") { store.transferPicked(.copy, includePairs: includePairs && !pairs.isEmpty) }
                    .disabled(count == 0)
                Button("移动到…") { store.transferPicked(.move, includePairs: includePairs && !pairs.isEmpty) }
                    .disabled(count == 0)
                Button("转换为 HEIF…") { convertingToHEIF = true }
                    .disabled(count == 0)
                    .help("把标记的照片转换为 HEIF 保存到别的文件夹,原文件不动")

                Divider().frame(height: 16)

                Button("删除", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(BarButtonStyle(color: .red))
                    .disabled(count == 0)
                    .help("把标记的照片移到废纸篓")
            }
        }
        .font(.callout)
        .buttonStyle(BarButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        // 一次删很多张,先确认一下(数量和是否带同名文件都写清楚)
        .confirmationDialog(
            withPairs ? "将标记的 \(count) 张照片连同 \(pairsText) 移到废纸篓?"
                      : "将标记的 \(count) 张照片移到废纸篓?",
            isPresented: $confirmingDelete
        ) {
            Button("移到废纸篓", role: .destructive) { store.trashPicked(includePairs: withPairs) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可以在废纸篓里恢复。")
        }
        .sheet(isPresented: $convertingToHEIF) { HEIFExportSheet().environmentObject(store) }
    }
}
