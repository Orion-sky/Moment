import SwiftUI
import Combine

/// 缩略图 / 瀑布流共用的右键菜单
struct PhotoContextMenu: View {
    @EnvironmentObject var store: ImageStore
    let index: Int

    var body: some View {
        let targets = store.targets(forContextAt: index)
        Button(targets.count > 1 ? "拷贝 \(targets.count) 张照片" : "拷贝") { store.copyToPasteboard(targets) }
        Divider()
        // 只是不再显示,文件不动
        Button(targets.count > 1 ? "从列表中移除 \(targets.count) 张照片" : "从列表中移除") { store.removeFromList(targets) }
        Button(targets.count > 1 ? "将 \(targets.count) 张照片移到废纸篓" : "移到废纸篓",
               role: .destructive) { store.trash(targets) }
        // 这些照片里有同名 RAW 时才出现
        // 这些照片有同名文件时才出现:看 JPG 时是带上 RAW,看 RAW 时是带上 JPG
        let pairs = store.pairs(for: targets)
        let pairsText = ImageStore.describe(pairs, of: store.urls(at: targets))
        if !pairs.isEmpty {
            Button(targets.count > 1 ? "将 \(targets.count) 张照片连同 \(pairsText) 一起移到废纸篓"
                                     : "连同 \(pairsText) 一起移到废纸篓",
                   role: .destructive) { store.trash(targets, withPairs: true) }
        }
        Divider()
        Button("在访达中显示") { store.revealInFinder(targets) }
    }
}
