import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

/// 按格式筛选显示的照片
enum FileFilter: String, CaseIterable, Identifiable {
    case jpg = "JPG", raw = "RAW", all = "全部"
    var id: Self { self }

    nonisolated func matches(_ url: URL) -> Bool {
        switch self {
        case .jpg: return ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        case .raw: return ImageMeta.isRAW(url)
        case .all: return true
        }
    }
}
