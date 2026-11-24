import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// 把照片转换成 HEIF(.heic)。原文件不动,拍摄参数(EXIF、GPS 等)原样保留。
///
/// - JPG / PNG 等:直接按新的画质重新压缩。
/// - RAW:从原始数据解码后直接压缩成 10 位 HEIF,不经过 JPEG,只压缩一次,
///   天空等渐变也不容易出现色带。
nonisolated enum HEIFConverter {
    struct ConversionError: LocalizedError {
        let errorDescription: String?
    }

    /// - Parameter quality: 画质,0~1
    static func convert(_ source: URL, to target: URL, quality: Double) throws {
        if ImageMeta.isRAW(source) {
            try convertRAW(source, to: target, quality: quality)
        } else {
            try convertBitmap(source, to: target, quality: quality)
        }
        // 文件日期跟原片一致,按日期排序时还在原来的位置
        if let dates = try? FileManager.default.attributesOfItem(atPath: source.path) {
            var copy: [FileAttributeKey: Any] = [:]
            copy[.creationDate] = dates[.creationDate]
            copy[.modificationDate] = dates[.modificationDate]
            try? FileManager.default.setAttributes(copy, ofItemAtPath: target.path)
        }
    }

    private static func convertBitmap(_ source: URL, to target: URL, quality: Double) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError(errorDescription: "无法读取这张照片")
        }
        guard let output = CGImageDestinationCreateWithURL(target as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw ConversionError(errorDescription: "无法创建 HEIF 文件")
        }
        // 直接从原图添加:像素和全部元数据(包括旋转方向)一起带过去,只按新画质重新压缩
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImageFromSource(output, input, 0, options)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: target)
            throw ConversionError(errorDescription: "HEIF 编码失败")
        }
    }

    private static func convertRAW(_ source: URL, to target: URL, quality: Double) throws {
        guard let filter = CIRAWFilter(imageURL: source), let decoded = filter.outputImage else {
            throw ConversionError(errorDescription: "无法解码这个 RAW 文件")
        }
        // 元数据从 RAW 文件里取。解码时已经按方向转正了,方向要改成"正常",否则看图软件会再转一次
        var properties: [String: Any] = [:]
        if let input = CGImageSourceCreateWithURL(source as CFURL, nil),
           let raw = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any] {
            properties = raw
        }
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        // 这些描述的是 RAW 本身的像素格式,对新文件不成立
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            properties[key as String] = nil
        }
        let image = decoded.settingProperties(properties)

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        // 用完就释放,长期留着会一直占几十 MB(见 ImageMeta.decodeRAW)
        let context = CIContext(options: [.cacheIntermediates: false])
        do {
            try context.writeHEIF10Representation(of: image, to: target, colorSpace: colorSpace, options: options)
        } catch {
            // 个别情况下 10 位写不出来,退回 8 位
            try? FileManager.default.removeItem(at: target)
            try context.writeHEIFRepresentation(of: image, to: target, format: .RGBA8,
                                                colorSpace: colorSpace, options: options)
        }
    }

    /// 目标文件夹里不重名的文件名:IMG_0001.heic、IMG_0001 2.heic、IMG_0001 3.heic……
    /// - Parameter taken: 这一批里已经用掉的名字(同名的 JPG 和 RAW 都转换时不会互相覆盖)
    static func uniqueTarget(for source: URL, in folder: URL, taken: inout Set<String>) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        var name = "\(stem).heic"
        var n = 2
        while taken.contains(name.lowercased())
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem) \(n).heic"
            n += 1
        }
        taken.insert(name.lowercased())
        return folder.appendingPathComponent(name)
    }
}
