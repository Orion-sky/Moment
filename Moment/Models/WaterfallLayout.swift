import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

/// 瀑布流排版:依次把每张图放进当前最矮的一列
nonisolated enum WaterfallLayout {
    static let spacing: CGFloat = 6
    /// 右侧额外留给滚动条的空隙,免得滚动条压在最右一列照片上
    static let scrollbarGutter: CGFloat = 9
    /// 主图四周的留白(ZoomableImage 用同一个值)
    static let viewerPadding: CGFloat = 12

    /// - Parameter topInset: 内容顶部留出的高度(工具栏)。第一排照片从它下面开始,滚动后会滚到工具栏后面
    static func make(_ aspects: [CGFloat], width: CGFloat, columns: Int, topInset: CGFloat = 0) -> (frames: [CGRect], height: CGFloat) {
        let count = min(max(columns, 1), 20)
        let colWidth = max(1, (width - scrollbarGutter - spacing * CGFloat(count + 1)) / CGFloat(count))
        var heights = [CGFloat](repeating: topInset + spacing, count: count)
        var frames: [CGRect] = []
        frames.reserveCapacity(aspects.count)
        for aspect in aspects {
            var c = 0
            for i in 0..<count where heights[i] < heights[c] { c = i }
            let h = colWidth / aspect
            frames.append(CGRect(x: spacing + CGFloat(c) * (colWidth + spacing), y: heights[c], width: colWidth, height: h))
            heights[c] += h + spacing
        }
        return (frames, heights.max() ?? 0)
    }

    /// 让第 index 张居中时的滚动位置
    static func centeredOffset(_ layout: (frames: [CGRect], height: CGFloat), index: Int,
                               viewHeight: CGFloat, topInset: CGFloat = 0) -> CGFloat {
        guard layout.frames.indices.contains(index) else { return 0 }
        // 在没被工具栏挡住的那部分里居中
        let y = layout.frames[index].midY - (viewHeight + topInset) / 2
        return min(max(y, 0), max(0, layout.height - viewHeight))
    }

    /// 主图在显示区域里按比例适应后的位置
    static func fitRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        let w = max(size.width - viewerPadding * 2, 1), h = max(size.height - viewerPadding * 2, 1)
        let fw = min(w, h * aspect), fh = fw / aspect
        return CGRect(x: (size.width - fw) / 2, y: (size.height - fh) / 2, width: fw, height: fh)
    }
}
