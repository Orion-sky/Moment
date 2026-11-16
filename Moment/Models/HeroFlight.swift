import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

/// 模式切换时的衔接动画:选中的照片从 `from` 飞到 `to`(坐标相对于照片显示区域的左上角)
struct HeroFlight: Identifiable {
    let id = UUID()
    let image: NSImage
    let from: CGRect
    let to: CGRect
    /// 终点是瀑布流里的格子(否则终点是主图位置)
    let endsInCell: Bool
}
