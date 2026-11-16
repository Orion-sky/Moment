import SwiftUI
import Combine

struct ThumbnailCell: View {
    let url: URL
    var picked = false
    let selected: Bool
    /// 是否是主图正在显示的那一张
    let current: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor.opacity(current ? 1 : 0.6), lineWidth: current ? 3 : (selected ? 2 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(selected && !current ? 0.25 : 0)))
        .overlay(alignment: .topTrailing) {
            if picked { PickBadge(size: 16).padding(4) }
        }
        .task(id: url) {
            // 删除后同一个格子会换成另一张图,先换成新图的缓存(没有则清空)
            image = ThumbnailCache.shared.cached(url)
            if image == nil { image = await ThumbnailCache.shared.load(url) }
        }
    }
}
