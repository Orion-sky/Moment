import SwiftUI
import Combine
import AppKit

struct WaterfallCell: View {
    let url: URL
    /// 需要的图片尺寸(最长边像素),见 ThumbnailCache.waterfallSizes
    let pixelSize: Int
    /// 在瀑布流里的位置,加载队列按它到当前关注点的距离排先后
    let point: CGPoint
    let fallback: NSImage?
    var picked = false
    let selected: Bool
    let current: Bool
    @State private var image: NSImage?
    /// `image` 目前显示的是哪个文件
    @State private var shownURL: URL?

    private struct LoadKey: Hashable {
        let url: URL
        let size: Int
    }

    var body: some View {
        Color.secondary.opacity(0.15)
            .overlay {
                if let image = image ?? fallback {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(selected && !current ? 0.25 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(current ? 1 : 0.6), lineWidth: current ? 3 : (selected ? 2 : 0)))
            .overlay(alignment: .topTrailing) {
                if picked { PickBadge(size: 22).padding(6) }
            }
            .contentShape(Rectangle())
            .task(id: LoadKey(url: url, size: pixelSize)) {
                let cache = ThumbnailCache.shared
                if let exact = cache.cached(url, size: pixelSize) {
                    image = exact
                } else {
                    // 先用手头最清晰的图占位。同一张照片只是换了尺寸(调了列数)时,保留正在显示的图;
                    // 有主图顶着时不用模糊的小图,避免"清晰 → 模糊 → 清晰"地跳
                    if let other = cache.bestCached(url), fallback == nil || other.size.width > 200 {
                        image = other
                    } else if shownURL != url {
                        image = nil
                    }
                    shownURL = url
                    if let full = await cache.load(url, size: pixelSize, point: point) { image = full }
                }
                shownURL = url
            }
    }
}
