import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

// MARK: 照片尺寸的读取(瀑布流排版用)

extension ImageStore {
    /// 把一个新读到的比例用到排版里,或者先攒着。返回 true 表示直接写进了 `into`
    private func route(_ index: Int, _ value: CGFloat, tolerance: CGFloat, into layout: inout [CGFloat]) {
        // 和占位用的比例几乎一样就不改,免得为了肉眼看不出的差别重排一次
        guard abs(layout[index] - value) / value > tolerance else { return }
        if mode == .waterfall, let rendered = waterfallRenderedRange, index <= rendered.upperBound {
            pendingAspects[index] = value
        } else {
            layout[index] = value
        }
    }

    /// 把攒着的比例一次性用到排版里
    func flushPendingAspects() {
        guard !pendingAspects.isEmpty else { return }
        var updated = aspects
        for (i, value) in pendingAspects where updated.indices.contains(i) { updated[i] = value }
        pendingAspects = [:]
        aspects = updated
    }

    /// 屏幕里的照片尺寸都读齐了、并且其中有攒着没用上的:这时一次性用上。
    /// 表现为进入瀑布流或跳到新位置后不久,画面整理一次,之后就不动了。
    private func settlePendingAspects() {
        guard let rendered = waterfallRenderedRange, !pendingAspects.isEmpty else { return }
        let range = rendered.clamped(to: 0...max(aspectKnown.count - 1, 0))
        guard pendingAspects.keys.contains(where: { range.contains($0) }),
              range.allSatisfy({ aspectKnown.indices.contains($0) && aspectKnown[$0] }) else { return }
        flushPendingAspects()
    }

    /// 下一批要读的照片:从屏幕顶部那张开始往下(马上要看到的),读完再往上
    private func nextAspectBatch(_ count: Int) -> [Int] {
        guard !aspectKnown.isEmpty else { return [] }
        let pivot = min(max(waterfallRenderedRange?.lowerBound ?? selection, 0), aspectKnown.count - 1)
        var batch: [Int] = []
        var i = pivot
        while i < aspectKnown.count, batch.count < count {
            if !aspectKnown[i] { batch.append(i) }
            i += 1
        }
        i = pivot - 1
        while i >= 0, batch.count < count {
            if !aspectKnown[i] { batch.append(i) }
            i -= 1
        }
        return batch
    }

    /// 后台分批读取图片尺寸(只读文件头,不解码)。
    /// - Parameter restart: false 时,如果已经在读就什么都不做
    func loadAspects(restart: Bool = true) {
        if !restart, aspectTask != nil { return }
        aspectTask?.cancel()
        aspectTask = nil
        guard aspectKnown.contains(false) else { return }

        // 列表变化(删除 / 换筛选 / 换文件夹)时会先取消本任务再改数组,所以下标始终对得上
        aspectTask = Task {
            while true {
                // 每一批都按当前屏幕位置重新挑,滚到哪就先读哪
                let batch = nextAspectBatch(64)
                if batch.isEmpty { break }
                let chunk = batch.map { images[$0] }
                let values = await Task.detached(priority: .utility) { ImageMeta.aspects(chunk) }.value
                guard !Task.isCancelled else { return }
                var updated = aspects
                var newlyKnown = 0
                for (k, value) in values.enumerated() {
                    let i = batch[k]
                    // 这张的比例可能已经从解码出的图片得知了(见 noteAspect),不重复处理
                    guard !aspectKnown[i] else { continue }
                    aspectCache[chunk[k]] = value
                    aspectKnown[i] = true
                    newlyKnown += 1
                    route(i, value, tolerance: 0.01, into: &updated)
                }
                if updated != aspects { aspects = updated }
                if newlyKnown > 0 { aspectsLoaded += newlyKnown }
                settlePendingAspects()
            }
            // 全部读完:把还攒着的一次性用上
            flushPendingAspects()
            aspectTask = nil
        }
    }

    /// 任何一张图解码出来(缩略图或主图)时,顺便记下它的真实宽高比。
    func noteAspect(_ url: URL, _ value: CGFloat) {
        guard value.isFinite, value > 0, aspectCache[url] == nil else { return }
        let aspect = min(max(value, 0.3), 3.5)
        aspectCache[url] = aspect
        guard let i = images.firstIndex(of: url), aspectKnown.indices.contains(i), !aspectKnown[i] else { return }
        aspectKnown[i] = true
        // 小缩略图量出来的比例有 1–2% 的误差,差别在这个范围内就沿用已有的值
        var updated = aspects
        route(i, aspect, tolerance: 0.025, into: &updated)
        if updated != aspects { aspects = updated }
        aspectsLoaded += 1
        settlePendingAspects()
    }
}
