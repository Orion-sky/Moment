import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

/// 缩略图加载:内存缓存 + 限制并发。
/// 按尺寸分别缓存:缩略图条用小图(优先取内嵌缩略图),瀑布流用较大的清晰图。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// 每解码出一张缩略图,报告它的真实宽高比
    var onAspect: ((URL, CGFloat) -> Void)?
    nonisolated static let stripSize = 200
    /// 瀑布流用的几档尺寸(最长边像素)。按格子实际大小选一档,
    /// 分档是为了列数、窗口稍微变化时还能用上已缓存的图
    /// 档位分得细一些:档位太粗时,需要 500 像素的格子会取到 720 的图,内存是实际需要的两倍
    nonisolated static let waterfallSizes = [320, 400, 480, 600, 720, 900, 1080, 1320, 1600]

    /// 能把 `pixels`(格子最长边的实际像素数)显示清楚的最小一档
    nonisolated static func waterfallSize(forPixels pixels: CGFloat) -> Int {
        waterfallSizes.first { CGFloat($0) >= pixels * 0.9 } ?? waterfallSizes[waterfallSizes.count - 1]
    }

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // 约 128 MB 像素数据。屏幕上正在显示的图由格子自己拿着,不受这个上限影响;
        // 这个上限只决定滚走之后还留多少张备用
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()
    /// 同时最多读几张。已经开始读的停不下来,所以不能太多:
    /// 太多的话滚到新位置后,要等一大批旧位置的图读完才轮到眼前的
    private let limiter = Limiter(max: max(3, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))

    private func key(_ url: URL, _ size: Int) -> NSString { "\(size)|\(url.path)" as NSString }

    func cached(_ url: URL, size: Int = stripSize) -> NSImage? { cache.object(forKey: key(url, size)) }

    /// 清空缓存。屏幕上正在显示的图由各自的格子拿着,不受影响
    func removeAll() { cache.removeAllObjects() }

    /// 已缓存的最清晰的一张(任何尺寸),用来占位
    func bestCached(_ url: URL) -> NSImage? {
        for size in Self.waterfallSizes.reversed() {
            if let hit = cached(url, size: size) { return hit }
        }
        return cached(url)
    }

    /// 告诉加载队列"现在最想看的位置"(瀑布流里的内容坐标);离它越近的格子越先加载
    func setFocus(_ point: CGPoint) {
        Task { await limiter.setFocus(point) }
    }

    /// - Parameter point: 这张图在瀑布流里的位置。排队时按它到当前关注点的距离决定先后
    func load(_ url: URL, size: Int = stripSize, point: CGPoint? = nil) async -> NSImage? {
        if let hit = cached(url, size: size) { return hit }
        // 排队期间格子滚出屏幕会被取消,直接放弃
        guard await limiter.acquire(point: point) else { return nil }
        if Task.isCancelled { await limiter.release(); return nil }
        let embedded = size <= Self.stripSize
        let cg = await Task.detached(priority: .medium) {
            autoreleasepool {
                embedded ? ImageMeta.thumbnail(url, maxPixel: size, preferEmbedded: true)
                         : ImageMeta.gridThumbnail(url, maxPixel: size)
            }
        }.value
        await limiter.release()
        guard let cg else { return nil }
        onAspect?(url, CGFloat(cg.width) / CGFloat(max(cg.height, 1)))
        let img = NSImage(cgImage: cg, size: .zero)
        cache.setObject(img, forKey: key(url, size), cost: cg.bytesPerRow * cg.height)
        return img
    }
}

/// 并发限制器。
/// - 发放名额时才决定先后:带位置的请求里,离"当前关注点"最近的先执行。
///   关注点随滚动实时更新,所以排着队的请求会跟着重新排序——滚到哪就先加载哪。
/// - 不带位置的请求(缩略图条)后来的先执行。
/// - 同一时刻涌入的一批请求会先攒几毫秒再一起排序,
///   否则最先到的几个会不看先后直接拿走名额。
/// - 被取消的请求立即出队,不占位置。
actor Limiter {
    private var available: Int
    private var waiters: [(id: UUID, point: CGPoint?, cont: CheckedContinuation<Bool, Never>)] = []
    private var drainScheduled = false
    private var focus: CGPoint = .zero
    init(max: Int) { available = max }

    func setFocus(_ point: CGPoint) { focus = point }

    /// 返回 false 表示等待期间被取消,未获得名额
    func acquire(point: CGPoint? = nil) async -> Bool {
        if Task.isCancelled { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                waiters.append((id, point, cont))
                scheduleDrain()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        available += 1
        drain()
    }

    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(returning: false)
    }

    private func scheduleDrain() {
        guard available > 0, !drainScheduled else { return }
        drainScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(8))
            drain()
        }
    }

    private func drain() {
        drainScheduled = false
        while available > 0, !waiters.isEmpty {
            // 带位置的:离关注点最近的;都不带位置:最后来的
            var best = waiters.count - 1
            var bestDistance = CGFloat.infinity
            for i in waiters.indices {
                guard let p = waiters[i].point else { continue }
                let d = hypot(p.x - focus.x, p.y - focus.y)
                if d < bestDistance { bestDistance = d; best = i }
            }
            available -= 1
            waiters.remove(at: best).cont.resume(returning: true)
        }
    }
}
