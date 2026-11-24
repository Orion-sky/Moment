import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

// MARK: 筛选模式(挑片):标记、复制 / 移动、删除

extension ImageStore {
    struct TransferProgress {
        let verb: String
        var done: Int
        let total: Int
    }

    enum TransferKind {
        case copy, move
        var verb: String { self == .copy ? "复制" : "移动" }
    }

    /// 当前列表里被标记的张数
    var pickedCountInList: Int { images.count { picked.contains($0) } }

    /// 标记 / 取消标记:多选了几张就作用于这几张,否则作用于当前这张。
    /// 这几张已经全部标记时是取消,否则是全部标记
    func togglePick() {
        let targets = (selected.count > 1 ? selected : [selection])
            .filter { images.indices.contains($0) }.map { images[$0] }
        guard !targets.isEmpty else { return }
        if targets.allSatisfy(picked.contains) { picked.subtract(targets) } else { picked.formUnion(targets) }
    }

    /// 全选:标记当前列表里的所有照片
    func pickAll() { picked.formUnion(images) }

    /// 反选:当前列表里标记的取消、没标记的标记(不在当前列表里的不动)
    func invertPicks() { picked.formSymmetricDifference(images) }

    func clearPicks() { picked = [] }

    /// 标记的照片还有哪些没被标记的同名文件(标记 JPG 时是 RAW,标记 RAW 时是 JPG)
    var pickedPairs: [URL] { siblings(of: picked) }

    /// 把标记的照片移到废纸篓(可以在废纸篓里恢复)
    func trashPicked(includePairs: Bool) {
        guard transfer == nil, !picked.isEmpty else { return }
        var wanted = picked
        if includePairs { wanted.formUnion(pickedPairs) }
        let sources = allImages.filter(wanted.contains)
        guard !sources.isEmpty else { return }

        transfer = TransferProgress(verb: "删除", done: 0, total: sources.count)
        Task {
            var succeeded: Set<URL> = []
            var failures: [String] = []
            for source in sources {
                let error = await Task.detached(priority: .userInitiated) { () -> Error? in
                    do { try FileManager.default.trashItem(at: source, resultingItemURL: nil); return nil }
                    catch { return error }
                }.value
                if let error { failures.append("\(source.lastPathComponent):\(error.localizedDescription)") }
                else { succeeded.insert(source) }
                transfer?.done += 1
            }
            transfer = nil
            dropFromLists(succeeded)
            // 全部成功就不打扰;有没删掉的才提示
            if !failures.isEmpty {
                alertTitle = "删除未全部完成"
                errorMessage = "已将 \(succeeded.count) 个文件移到废纸篓。\n\n\(failures.count) 个失败:\n"
                    + failures.prefix(5).joined(separator: "\n")
            }
        }
    }

    /// 把标记的照片复制或移动到用户选择的文件夹
    func transferPicked(_ kind: TransferKind, includePairs: Bool) {
        #if os(macOS)
        guard transfer == nil, !picked.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "\(kind.verb)到这里"
        panel.message = "选择要\(kind.verb)到的文件夹"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if destination.standardizedFileURL == folder?.standardizedFileURL {
            alertTitle = "无法\(kind.verb)"
            errorMessage = "目标文件夹就是当前打开的文件夹,请选择另一个文件夹。"
            return
        }

        // 按文件夹里的顺序处理;需要时带上同名 RAW
        var wanted = picked
        if includePairs { wanted.formUnion(pickedPairs) }
        let sources = allImages.filter(wanted.contains)
        guard !sources.isEmpty else { return }

        transfer = TransferProgress(verb: kind.verb, done: 0, total: sources.count)
        Task {
            var succeeded: Set<URL> = []
            var skipped: [String] = []
            var failures: [String] = []
            for source in sources {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                // 文件读写放到后台线程,从 SD 卡拷大文件时界面不会卡住
                let copying = kind == .copy
                let result = await Task.detached(priority: .userInitiated) { () -> Result<Bool, Error> in
                    // 目标位置已有同名文件:跳过,绝不覆盖
                    if FileManager.default.fileExists(atPath: target.path) { return .success(false) }
                    do {
                        if copying { try FileManager.default.copyItem(at: source, to: target) }
                        else { try FileManager.default.moveItem(at: source, to: target) }
                        return .success(true)
                    } catch {
                        return .failure(error)
                    }
                }.value
                switch result {
                case .success(true): succeeded.insert(source)
                case .success(false): skipped.append(source.lastPathComponent)
                case .failure(let error): failures.append("\(source.lastPathComponent):\(error.localizedDescription)")
                }
                transfer?.done += 1
            }
            transfer = nil
            // 移走的文件已经不在这个文件夹里了
            if kind == .move { dropFromLists(succeeded) }

            var lines = ["已\(kind.verb) \(succeeded.count) 个文件到「\(destination.lastPathComponent)」。"]
            if !skipped.isEmpty {
                lines.append("\(skipped.count) 个因目标文件夹里已有同名文件而跳过:\n" + skipped.prefix(5).joined(separator: "\n"))
            }
            if !failures.isEmpty {
                lines.append("\(failures.count) 个失败:\n" + failures.prefix(5).joined(separator: "\n"))
            }
            alertTitle = failures.isEmpty ? "\(kind.verb)完成" : "\(kind.verb)未全部完成"
            errorMessage = lines.joined(separator: "\n\n")
        }
        #endif
    }

    // MARK: 转换为 HEIF

    private static let heifFolderKey = "heifExportFolderBookmark"

    /// 上次转换 HEIF 时保存到的文件夹(存成书签,沙盒下重启后也能直接用)
    var lastHEIFFolder: URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.heifFolderKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 选择 HEIF 的保存位置;选好后记下来,下次默认还是它
    func chooseHEIFFolder(startingAt current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current ?? folder
        panel.prompt = "选择"
        panel.message = "选择转换后的 HEIF 文件保存到哪个文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let data = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(data, forKey: Self.heifFolderKey)
        }
        return url
    }

    /// 把标记的照片转换成 HEIF 保存到 destination。原文件不动;目标位置有同名文件时自动改名,不覆盖
    /// - Parameter quality: 画质,0~1
    func convertPickedToHEIF(to destination: URL, quality: Double) {
        guard transfer == nil, !picked.isEmpty else { return }
        let sources = allImages.filter(picked.contains)
        guard !sources.isEmpty else { return }
        let scoped = destination.startAccessingSecurityScopedResource()

        transfer = TransferProgress(verb: "转换", done: 0, total: sources.count)
        Task {
            var taken: Set<String> = []
            var converted = 0
            var sizeBefore: Int64 = 0, sizeAfter: Int64 = 0
            var failures: [String] = []
            for source in sources {
                let target = HEIFConverter.uniqueTarget(for: source, in: destination, taken: &taken)
                // 解码和压缩都放到后台线程;一张一张来,RAW 全尺寸解码很占内存
                let result = await Task.detached(priority: .userInitiated) { () -> Result<(Int64, Int64), Error> in
                    do {
                        try HEIFConverter.convert(source, to: target, quality: quality)
                        func size(_ url: URL) -> Int64 {
                            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
                        }
                        return .success((size(source), size(target)))
                    } catch {
                        return .failure(error)
                    }
                }.value
                switch result {
                case .success(let (before, after)):
                    converted += 1
                    sizeBefore += before
                    sizeAfter += after
                case .failure(let error):
                    failures.append("\(source.lastPathComponent):\(error.localizedDescription)")
                }
                transfer?.done += 1
            }
            if scoped { destination.stopAccessingSecurityScopedResource() }
            transfer = nil

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            var lines = ["已转换 \(converted) 张照片到「\(destination.lastPathComponent)」。"]
            if converted > 0, sizeBefore > 0 {
                let percent = Int((Double(sizeAfter) / Double(sizeBefore) * 100).rounded())
                lines.append("原文件共 \(formatter.string(fromByteCount: sizeBefore)),"
                             + "转换后 \(formatter.string(fromByteCount: sizeAfter)),约为原来的 \(percent)%。")
            }
            if !failures.isEmpty {
                lines.append("\(failures.count) 张失败:\n" + failures.prefix(5).joined(separator: "\n"))
            }
            alertTitle = failures.isEmpty ? "转换完成" : "转换未全部完成"
            errorMessage = lines.joined(separator: "\n\n")
        }
    }
}
