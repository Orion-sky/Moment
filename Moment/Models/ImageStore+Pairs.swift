import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

// MARK: 同名文件(RAW + JPG 成对拍摄),以及对选中文件的操作

extension ImageStore {
    static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    func rebuildRAWIndex() {
        filesByStem = Dictionary(grouping: allImages, by: Self.stem)
    }

    /// 这些文件的同名文件(不含它们自己)。看 JPG 时得到的是 RAW,看 RAW 时得到的是 JPG
    func siblings(of urls: Set<URL>) -> [URL] {
        var seen = urls
        var result: [URL] = []
        for url in urls {
            for other in filesByStem[Self.stem(url)] ?? [] where seen.insert(other).inserted {
                result.append(other)
            }
        }
        return result
    }

    /// 这些照片的同名文件(即使当前筛选下没有显示出来)
    func pairs(for indices: Set<Int>) -> [URL] {
        siblings(of: Set(indices.filter { images.indices.contains($0) }.map { images[$0] }))
    }

    /// 一组同名文件该怎么称呼。
    /// 只有在情况很单纯时才说具体格式:选的全是 JPG、带上的全是 RAW → "3 个 RAW";反过来 → "3 个 JPG"。
    /// 选的照片本身就混着 RAW 和 JPG,或者带上的文件混着几种格式,都叫"3 个同名文件"。
    static func describe(_ pairs: [URL], of sources: some Collection<URL>) -> String {
        func isJPG(_ url: URL) -> Bool { ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) }
        let sourcesAllRAW = sources.allSatisfy(ImageMeta.isRAW)
        let sourcesNoRAW = !sources.contains(where: ImageMeta.isRAW)
        let kind: String
        if sourcesNoRAW, pairs.allSatisfy(ImageMeta.isRAW) { kind = "RAW" }
        else if sourcesAllRAW, pairs.allSatisfy(isJPG) { kind = "JPG" }
        else { kind = "同名文件" }
        return "\(pairs.count) 个\(kind == "同名文件" ? "" : " ")\(kind)"
    }

    /// 序号对应的文件
    func urls(at indices: Set<Int>) -> [URL] {
        indices.sorted().filter { images.indices.contains($0) }.map { images[$0] }
    }

    /// 把照片文件放进剪贴板:在访达里粘贴是拷贝文件,在聊天、邮件等应用里粘贴是插入照片
    func copyToPasteboard(_ indices: Set<Int>) {
        let files = urls(at: indices)
        guard !files.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects(files as [NSURL]) {
            edgeNotice = EdgeNotice(text: files.count > 1 ? "已拷贝 \(files.count) 张照片" : "已拷贝")
        } else {
            edgeNotice = EdgeNotice(text: "拷贝失败", duration: 2)
        }
    }

    /// 分享(隔空投送、信息、邮件等)要发送的照片:
    /// 筛选模式下是标记的照片(按操作条上的勾选带上同名文件),否则是选中的照片
    var shareFiles: [URL] {
        guard culling else { return urls(at: selected) }
        let includePairs = UserDefaults.standard.bool(forKey: "cullingIncludeRAW")
        let files = includePairs ? Array(picked) + pickedPairs : Array(picked)
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func revealInFinder(_ indices: Set<Int>) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting(indices.sorted().compactMap { images.indices.contains($0) ? images[$0] : nil })
        #endif
    }
}
