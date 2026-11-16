import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

/// 一条参数
struct MetaRow: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let value: String
}

struct MetaSection: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let rows: [MetaRow]
}

nonisolated enum ImageMeta {
    /// 读取图片参数(文件、尺寸、相机、曝光等)
    static func read(_ url: URL) -> [MetaSection] {
        var sections: [MetaSection] = []

        // 文件信息
        var file: [MetaRow] = [MetaRow(name: "文件名", value: url.lastPathComponent)]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = attrs[.size] as? Int64 {
                file.append(MetaRow(name: "大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
            }
            if let date = attrs[.modificationDate] as? Date {
                file.append(MetaRow(name: "修改时间", value: date.formatted(date: .abbreviated, time: .standard)))
            }
        }
        sections.append(MetaSection(title: "文件", rows: file))

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return sections
        }

        // 图像
        var img: [MetaRow] = []
        if let w = p[kCGImagePropertyPixelWidth], let h = p[kCGImagePropertyPixelHeight] {
            img.append(MetaRow(name: "尺寸", value: "\(w) × \(h)"))
        }
        if let m = p[kCGImagePropertyColorModel] as? String { img.append(MetaRow(name: "色彩模型", value: m)) }
        if let c = p[kCGImagePropertyProfileName] as? String { img.append(MetaRow(name: "色彩配置", value: c)) }
        if let d = p[kCGImagePropertyDepth] { img.append(MetaRow(name: "位深", value: "\(d)")) }
        if let o = p[kCGImagePropertyOrientation] as? Int { img.append(MetaRow(name: "方向", value: describeOrientation(o))) }
        if !img.isEmpty { sections.append(MetaSection(title: "图像", rows: img)) }

        // 相机
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var cam: [MetaRow] = []
        if let v = tiff[kCGImagePropertyTIFFMake] { cam.append(MetaRow(name: "厂商", value: "\(v)")) }
        if let v = tiff[kCGImagePropertyTIFFModel] { cam.append(MetaRow(name: "型号", value: "\(v)")) }
        if let v = exif[kCGImagePropertyExifLensModel] { cam.append(MetaRow(name: "镜头", value: "\(v)")) }
        if let v = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            cam.append(MetaRow(name: "拍摄时间", value: formatEXIFDate(v)))
        }
        if !cam.isEmpty { sections.append(MetaSection(title: "相机", rows: cam)) }

        // 曝光
        var exp: [MetaRow] = []
        if let v = exif[kCGImagePropertyExifFNumber] as? Double { exp.append(MetaRow(name: "光圈", value: String(format: "f/%.1f", v))) }
        if let v = exif[kCGImagePropertyExifExposureTime] as? Double, v > 0 {
            exp.append(MetaRow(name: "快门", value: v < 1 ? "1/\(Int((1 / v).rounded())) s" : "\(v) s"))
        }
        if let v = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first { exp.append(MetaRow(name: "ISO", value: "\(v)")) }
        if let v = exif[kCGImagePropertyExifFocalLength] as? Double { exp.append(MetaRow(name: "焦距", value: String(format: "%.0f mm", v))) }
        if let v = equivalentFocalLength(exif: exif, properties: p) { exp.append(MetaRow(name: "等效焦距", value: v)) }
        if let v = exif[kCGImagePropertyExifExposureBiasValue] as? Double { exp.append(MetaRow(name: "曝光补偿", value: String(format: "%+.1f EV", v))) }
        if let v = exif[kCGImagePropertyExifFlash] as? Int { exp.append(MetaRow(name: "闪光灯", value: describeFlash(v))) }
        if !exp.isEmpty { sections.append(MetaSection(title: "曝光", rows: exp)) }

        // GPS
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            sections.append(MetaSection(title: "位置", rows: [
                MetaRow(name: "坐标", value: String(format: "%.5f, %.5f", lat, lon))
            ]))
        }
        return sections
    }

    /// 方向:照片里记的是 1–8 的编号,表示显示时要怎么转才是正的。
    /// 应用显示时已经按它转正了,这里说明的是相机当时的拍法
    static func describeOrientation(_ value: Int) -> String {
        switch value {
        case 1: "横拍"
        case 3: "横拍(相机倒置)"
        case 6: "竖拍(相机顺时针转 90°)"
        case 8: "竖拍(相机逆时针转 90°)"
        case 2: "横拍(左右镜像)"
        case 4: "横拍(上下镜像)"
        case 5: "竖拍(镜像)"
        case 7: "竖拍(镜像)"
        default: "未知(\(value))"
        }
    }

    /// 闪光灯:照片里记的是一个按位组合的数字,拆成"有没有闪"和"什么模式"
    static func describeFlash(_ value: Int) -> String {
        // 第 5 位:相机没有闪光灯
        if value & 0x20 != 0 { return "无闪光灯" }
        var parts = [value & 0x01 != 0 ? "已闪光" : "未闪光"]
        // 第 3–4 位:模式
        switch (value >> 3) & 0x03 {
        case 1: parts.append("强制开启")
        case 2: parts.append("强制关闭")
        case 3: parts.append("自动")
        default: break
        }
        // 第 6 位:防红眼
        if value & 0x40 != 0 { parts.append("防红眼") }
        // 第 1–2 位:有没有检测到反射回来的闪光(只有闪了才有意义)
        if value & 0x01 != 0 {
            switch (value >> 1) & 0x03 {
            case 2: parts.append("未检测到回光")
            case 3: parts.append("检测到回光")
            default: break
            }
        }
        return parts.joined(separator: ",")
    }

    /// 35mm 等效焦距。
    /// 相机一般会直接把它写在照片里,有就用它;没有的话,用焦平面分辨率推算传感器尺寸,
    /// 再按对角线和全画幅(43.27 mm)的比值换算,这种情况前面加"约"。都没有就不显示。
    static func equivalentFocalLength(exif: [CFString: Any], properties: [CFString: Any]) -> String? {
        if let recorded = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double, recorded > 0 {
            return String(format: "%.0f mm", recorded)
        }
        guard let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0,
              let xRes = exif[kCGImagePropertyExifFocalPlaneXResolution] as? Double, xRes > 0,
              let yRes = exif[kCGImagePropertyExifFocalPlaneYResolution] as? Double, yRes > 0 else { return nil }
        // 焦平面分辨率的单位:2 英寸、3 厘米、4 毫米、5 微米;没写按英寸
        let unitMM: Double
        switch exif[kCGImagePropertyExifFocalPlaneResolutionUnit] as? Int ?? 2 {
        case 3: unitMM = 10
        case 4: unitMM = 1
        case 5: unitMM = 0.001
        default: unitMM = 25.4
        }
        // 这个分辨率对应的是相机记录的原始像素数,不一定等于文件现在的像素数(可能被缩小过)
        guard let pixelsX = (exif[kCGImagePropertyExifPixelXDimension] ?? properties[kCGImagePropertyPixelWidth]) as? Double,
              let pixelsY = (exif[kCGImagePropertyExifPixelYDimension] ?? properties[kCGImagePropertyPixelHeight]) as? Double,
              pixelsX > 0, pixelsY > 0 else { return nil }
        let sensorW = pixelsX / xRes * unitMM
        let sensorH = pixelsY / yRes * unitMM
        let diagonal = (sensorW * sensorW + sensorH * sensorH).squareRoot()
        // 算出来的传感器小得或大得离谱,说明这些数据不可靠,宁可不显示
        guard diagonal > 3, diagonal < 80 else { return nil }
        return String(format: "约 %.0f mm", focal * 43.27 / diagonal)
    }

    /// EXIF 里的时间是 "2024:05:01 12:34:56" 这种写法,转成和"修改时间"一致的本地格式。
    /// EXIF 时间不带时区,记录的就是相机上显示的时刻,所以按原样的时分秒显示,不做时区换算。
    static func formatEXIFDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw.trimmingCharacters(in: .whitespaces)) else { return raw }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    static let rawExts: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw", "raw"]

    static func isRAW(_ url: URL) -> Bool { rawExts.contains(url.pathExtension.lowercased()) }


    /// 用系统 RAW 引擎真正解码(而不是取内嵌 JPG 预览),并缩放到 maxPixel
    static func decodeRAW(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        let longest = max(native.width, native.height)
        if longest > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixel) / longest)) }
        guard let out = filter.outputImage else { return nil }
        // 每次解码临时建一个渲染环境,用完就释放。
        // 长期留着一个的话,它自己会一直占着几十 MB(实测约 46 MB),而建一个的开销相比 RAW 解码可以忽略
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(out, from: out.extent)
    }

    /// 宽高比(宽/高),只读文件头;考虑了 EXIF 旋转。读不到时按 3:2
    static func aspect(_ url: URL) -> CGFloat {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = p[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return 1.5 }
        let rotated = ((p[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let a = rotated ? h / w : w / h
        return min(max(a, 0.3), 3.5)
    }

    /// 并行读取一批图片的宽高比
    static func aspects(_ urls: [URL]) -> [CGFloat] {
        var out = [CGFloat](repeating: 1.5, count: urls.count)
        out.withUnsafeMutableBufferPointer { buf in
            nonisolated(unsafe) let base = buf.baseAddress
            // 只用两路并行:读尺寸是给排版用的后台工作,不能把存储卡的读取能力占满,
            // 否则屏幕上正等着的缩略图反而读不出来(RAW 文件尤其明显)
            let lanes = 2
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                for i in stride(from: lane, to: urls.count, by: lanes) {
                    // 每个文件单独释放临时对象,否则一整批读完之前都不会释放
                    autoreleasepool { base?[i] = aspect(urls[i]) }
                }
            }
        }
        return out
    }

    /// 生成缩略图(在后台线程调用)
    /// - Parameter preferEmbedded: 优先使用文件内嵌的缩略图(快很多,不必解码原图);没有内嵌图时才从原图生成
    static func thumbnail(_ url: URL, maxPixel: Int, preferEmbedded: Bool = false) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            (preferEmbedded ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                            : kCGImageSourceCreateThumbnailFromImageAlways): true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return preferEmbedded ? cropToTrueAspect(thumb, source: src) : thumb
    }

    /// 瀑布流用的清晰缩略图。
    /// RAW 文件里一般带着一张相机生成的 JPG 预览,够大就直接用它:
    /// 完整解码一张 RAW 要一两秒,而且开始了就停不下来,滚动时会把加载队列堵住。
    static func gridThumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        if isRAW(url), let preview = thumbnail(url, maxPixel: maxPixel, preferEmbedded: true),
           CGFloat(max(preview.width, preview.height)) >= CGFloat(maxPixel) * 0.6 {
            return preview
        }
        return thumbnail(url, maxPixel: maxPixel)
    }

    /// 相机内嵌的缩略图常是固定 4:3,照片不是 4:3 时会被补上黑边。
    /// 按照片的真实宽高比居中裁剪,把黑边去掉。
    private static func cropToTrueAspect(_ thumb: CGImage, source: CGImageSource) -> CGImage {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = p[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return thumb }
        let rotated = ((p[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let trueAspect = rotated ? h / w : w / h
        let tw = CGFloat(thumb.width), th = CGFloat(thumb.height)
        let thumbAspect = tw / th
        guard abs(thumbAspect - trueAspect) / trueAspect > 0.02 else { return thumb }

        var rect = CGRect(x: 0, y: 0, width: tw, height: th)
        if thumbAspect < trueAspect {
            // 缩略图比照片"高":黑边在上下
            let newH = (tw / trueAspect).rounded(.down)
            rect = CGRect(x: 0, y: ((th - newH) / 2).rounded(), width: tw, height: newH)
        } else {
            // 缩略图比照片"宽":黑边在左右
            let newW = (th * trueAspect).rounded(.down)
            rect = CGRect(x: ((tw - newW) / 2).rounded(), y: 0, width: newW, height: th)
        }
        // 向内再收 1 像素,避开黑边与画面交界处的压缩毛边
        return thumb.cropping(to: rect.insetBy(dx: 1, dy: 1)) ?? thumb
    }
}
