import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum ViewMode: Hashable { case single, waterfall }

/// 模式切换时的衔接动画:选中的照片从 `from` 飞到 `to`(坐标相对于照片显示区域的左上角)
struct HeroFlight: Identifiable {
    let id = UUID()
    let image: NSImage
    let from: CGRect
    let to: CGRect
    /// 终点是瀑布流里的格子(否则终点是主图位置)
    let endsInCell: Bool
}

/// 瀑布流排版:依次把每张图放进当前最矮的一列
nonisolated enum WaterfallLayout {
    static let spacing: CGFloat = 6
    /// 右侧额外留给滚动条的空隙,免得滚动条压在最右一列照片上
    static let scrollbarGutter: CGFloat = 14
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

/// 管理当前文件夹、图片列表与选中项
@MainActor
final class ImageStore: ObservableObject {
    @Published var folder: URL?
    /// 当前筛选条件下显示的照片
    @Published var images: [URL] = []
    /// 文件夹里的全部照片(不受筛选影响)
    @Published private(set) var allImages: [URL] = []
    /// 只显示 JPG / 只显示 RAW / 全部,默认只显示 JPG
    @Published var filter: FileFilter = .jpg {
        didSet { if oldValue != filter { applyFilter() } }
    }
    /// 显示列表被整体替换(切换筛选 / 换文件夹)时加一,界面据此重新定位到当前照片
    @Published private(set) var listVersion = 0
    /// 已读到的尺寸,切换筛选时不用重读
    private var aspectCache: [URL: CGFloat] = [:]
    @Published var selection: Int = 0 { didSet { if oldValue != selection { loadCurrent() } } }
    @Published var mainImage: NSImage?
    @Published var meta: [MetaSection] = []
    /// 缩略图条里被选中的项(多选);主图显示的是 `selection`
    @Published var selected: Set<Int> = []
    /// 提示框:标题和内容(删除失败、复制 / 移动的结果)
    @Published var errorMessage: String?
    @Published var alertTitle = "无法删除"
    /// 普通模式(单张 + 缩略图条)或瀑布流模式
    @Published var mode: ViewMode = .single {
        didSet {
            guard oldValue != mode else { return }
            // 切换模式是一个自然的整理时机:把攒着的尺寸都用上
            if mode == .single { waterfallRenderedRange = nil }
            flushPendingAspects()
            loadAspects(restart: false)
            loadCurrent(immediate: true)
            startHero(from: oldValue)
        }
    }

    // MARK: 模式切换的衔接动画

    /// 正在进行的衔接动画;非 nil 时,真正的主图 / 选中的格子先隐藏,由飞行中的那张代替
    @Published var hero: HeroFlight?
    /// 以下三项由界面随时写入,只在切换的瞬间读取,不触发刷新
    var photoAreaSize: CGSize = .zero          // 照片显示区域(主图 / 瀑布流)当前的大小
    var trailingInset: CGFloat = 0             // 其中右侧被信息栏盖住的宽度
    var topInset: CGFloat = 0                  // 其中顶部被工具栏盖住的高度
    var stripExtraHeight: CGFloat = 0          // 普通模式下缩略图条占掉的高度
    var waterfallSelectionRect: CGRect?        // 选中的照片此刻在瀑布流里的位置

    private func startHero(from old: ViewMode) {
        hero = nil
        guard let image = mainImage, image.size.width > 0, image.size.height > 0,
              images.indices.contains(selection), aspects.count == images.count,
              photoAreaSize.width > 0, photoAreaSize.height > 0 else { return }

        // 两种模式下照片区域的大小:宽度一样,普通模式的高度要扣掉缩略图条
        // 照片区域现在始终是整块(信息栏和缩略图条都浮在它上面):
        // 两种模式都让出右边的信息栏;普通模式还要让出底部的缩略图条,瀑布流没有缩略图条
        // 顶部还要让出工具栏:两种模式下照片都从工具栏下方开始排
        let usableWidth = max(photoAreaSize.width - trailingInset, 1)
        let usableHeight = max(photoAreaSize.height - topInset, 1)
        // 瀑布流的滚动区域是整块高度(照片会滚到工具栏后面),工具栏的高度算在内容顶部的留白里
        let waterfallSize = CGSize(width: usableWidth, height: photoAreaSize.height)
        let singleSize = CGSize(width: usableWidth, height: max(usableHeight - stripExtraHeight, 1))
        let big = WaterfallLayout.fitRect(aspect: image.size.width / image.size.height, in: singleSize)
            .offsetBy(dx: 0, dy: topInset)

        let cell: CGRect
        if old == .waterfall {
            guard let rect = waterfallSelectionRect else { return }
            cell = rect
        } else {
            // 瀑布流还没创建:它进入时会把选中的照片居中,按同样的算法算出格子位置
            let saved = UserDefaults.standard.integer(forKey: "waterfallColumns")
            let layout = WaterfallLayout.make(aspects, width: waterfallSize.width,
                                              columns: saved == 0 ? 5 : saved, topInset: topInset)
            let y = WaterfallLayout.centeredOffset(layout, index: selection,
                                                   viewHeight: waterfallSize.height, topInset: topInset)
            cell = layout.frames[selection].offsetBy(dx: 0, dy: -y)
        }
        hero = old == .single ? HeroFlight(image: image, from: big, to: cell, endsInCell: true)
                              : HeroFlight(image: image, from: cell, to: big, endsInCell: false)
    }
    /// 每张图的宽高比(宽/高),与 `images` 一一对应,瀑布流排版用。
    /// 还没读到的先按 3:2 占位,后台分批读取后逐步更新。
    @Published var aspects: [CGFloat] = []
    /// 已读到真实尺寸的张数
    @Published var aspectsLoaded = 0
    private var aspectKnown: [Bool] = []
    private var aspectTask: Task<Void, Never>?
    /// Shift 范围选择的起点
    private var anchor = 0

    /// 缩放请求:倍率因子,0 表示复位为适应窗口
    let zoomRequests = PassthroughSubject<CGFloat, Never>()

    private var loadTask: Task<Void, Never>?

    init() {
        ThumbnailCache.shared.onAspect = { [weak self] url, aspect in self?.noteAspect(url, aspect) }
    }
    /// `mainImage` 目前显示的是哪个文件
    private var mainImageURL: URL?
    private var scanTask: Task<Void, Never>?

    var current: URL? { images.indices.contains(selection) ? images[selection] : nil }

    func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url { open(folder: url) }
        #endif
    }

    func open(folder url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        folder = url
        scanTask?.cancel()
        scanTask = Task {
            // 扫描与排序放到后台线程
            let list = await Task.detached(priority: .userInitiated) { Self.scan(url) }.value
            guard !Task.isCancelled else { return }
            allImages = list
            picked = []
            rebuildRAWIndex()
            aspectCache = [:]
            applyFilter()
        }
    }

    /// 切换筛选后应该选中哪一张:
    /// 同一个文件 → 同名不同格式的那张(如 IMG_0001.JPG ↔ IMG_0001.ARW)→ 按文件名顺序最接近的那张
    nonisolated private static func bestMatch(for url: URL, in list: [URL]) -> Int {
        if let i = list.firstIndex(of: url) { return i }
        let stem = url.deletingPathExtension().lastPathComponent
        if let i = list.firstIndex(where: {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
        }) { return i }
        let name = url.lastPathComponent
        let next = list.firstIndex { $0.lastPathComponent.localizedStandardCompare(name) != .orderedAscending }
        return next ?? max(0, list.count - 1)
    }

    /// 按当前筛选条件重建显示列表;当前照片还在列表里就保持选中它
    private func applyFilter() {
        let keep = current
        aspectTask?.cancel()
        aspectTask = nil
        pendingAspects = [:]
        waterfallRenderedRange = nil
        let list = allImages.filter(filter.matches)
        images = list
        // 还没读到尺寸的照片,先借用同名文件的比例(RAW 和它的 JPG 比例几乎总是一样),
        // 这样从 JPG 切到"全部"时,新出现的 RAW 一开始就在正确的位置,后面读到真实尺寸也不用再挪
        var stemAspect: [String: CGFloat] = [:]
        for (url, aspect) in aspectCache { stemAspect[Self.stem(url)] = aspect }
        aspects = list.map { aspectCache[$0] ?? stemAspect[Self.stem($0)] ?? 1.5 }
        aspectKnown = list.map { aspectCache[$0] != nil }
        aspectsLoaded = aspectKnown.count { $0 }
        let index = keep.map { Self.bestMatch(for: $0, in: list) } ?? 0
        listVersion += 1
        selected = list.isEmpty ? [] : [index]
        anchor = index
        if selection == index { loadCurrent() } else { selection = index }
        // 在后台预读尺寸,切到瀑布流时不用再等
        loadAspects()
    }

    nonisolated private static func scan(_ url: URL) -> [URL] {
        let imageExts: Set<String> = Set(
            ["jpg", "jpeg", "png", "gif", "tif", "tiff", "heic", "heif", "webp", "bmp", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw", "raw"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { imageExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 最近一次选中项变化是不是鼠标点出来的(缩略图条据此决定要不要重新居中)。不触发刷新
    private(set) var selectionByClick = false

    func move(_ delta: Int) {
        guard !images.isEmpty else { return }
        selectionByClick = false
        selection = min(max(selection + delta, 0), images.count - 1)
        selected = [selection]
        anchor = selection
    }

    /// 点击缩略图:普通点击单选,Shift 连选一段,Command 逐个加减
    func click(_ index: Int, shift: Bool, command: Bool) {
        guard images.indices.contains(index) else { return }
        selectionByClick = true
        if shift {
            selected = Set(min(anchor, index)...max(anchor, index))
        } else if command {
            if selected.contains(index), selected.count > 1 { selected.remove(index) } else { selected.insert(index) }
            anchor = index
        } else {
            selected = [index]
            anchor = index
        }
        if selected.contains(index) { selection = index }
        else if let first = selected.min() { selection = first }
    }

    /// 右键某一项时要操作的目标:右键在多选范围内则是整个多选,否则只是这一项
    func targets(forContextAt index: Int) -> Set<Int> {
        selected.contains(index) ? selected : [index]
    }

    /// 把指定图片移到废纸篓(可在废纸篓中恢复)
    /// - Parameter withPairs: 同时删除这些照片的同名文件(JPG 对应的 RAW,或 RAW 对应的 JPG),
    ///   即使当前筛选下没有显示出来
    func trash(_ requested: Set<Int>, withPairs: Bool = false) {
        var indices = requested
        // 同名文件:显示在当前列表里的按下标一起删;没显示出来的(比如只看 JPG 时的 RAW)单独删
        var hiddenRAWs: [URL] = []
        if withPairs {
            let position = Dictionary(uniqueKeysWithValues: images.enumerated().map { ($0.element, $0.offset) })
            for raw in pairs(for: requested) {
                if let i = position[raw] { indices.insert(i) } else { hiddenRAWs.append(raw) }
            }
        }

        var removed: Set<Int> = []
        var removedHidden: Set<URL> = []
        var failures: [String] = []
        for i in indices.sorted() where images.indices.contains(i) {
            do {
                try FileManager.default.trashItem(at: images[i], resultingItemURL: nil)
                removed.insert(i)
            } catch {
                failures.append("\(images[i].lastPathComponent):\(error.localizedDescription)")
            }
        }
        for url in hiddenRAWs {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                removedHidden.insert(url)
            } catch {
                failures.append("\(url.lastPathComponent):\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            alertTitle = "无法删除"
            errorMessage = "有 \(failures.count) 个文件未能移到废纸篓:\n" + failures.prefix(5).joined(separator: "\n")
        }
        dropFromLists(Set(removed.map { images[$0] }).union(removedHidden))
    }

    /// 这些文件已经不在文件夹里了(删除或移走):从各个列表里去掉,并停在原位置附近
    private func dropFromLists(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        // 序号会变,攒着的尺寸是按序号记的,先用上
        flushPendingAspects()
        let removed = Set(images.indices.filter { urls.contains(images[$0]) })
        allImages.removeAll { urls.contains($0) }
        picked.subtract(urls)
        rebuildRAWIndex()
        guard !removed.isEmpty else { return }

        // 当前项前面去掉了几个,就往前挪几个
        let shift = removed.filter { $0 < selection }.count
        aspectTask?.cancel()
        aspectTask = nil
        aspects = aspects.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        aspectKnown = aspectKnown.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        aspectsLoaded = aspectKnown.count { $0 }
        images = images.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let next = images.isEmpty ? 0 : min(max(selection - shift, 0), images.count - 1)
        selected = images.isEmpty ? [] : [next]
        anchor = next
        if selection == next { loadCurrent() } else { selection = next }
        loadAspects()   // 继续读还没读到的
    }

    // MARK: 筛选模式(挑片)

    /// 筛选模式开关:开着时可以用快捷键标记照片,并显示操作条
    @Published var culling = false
    /// 被标记(挑中)的照片。按文件记,切换 JPG / RAW 筛选或模式后仍然保留
    @Published private(set) var picked: Set<URL> = []
    /// 正在复制 / 移动时的进度
    @Published private(set) var transfer: TransferProgress?

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

    // MARK: 同名文件(RAW + JPG 成对拍摄)

    /// 文件名(不含扩展名、不分大小写)→ 叫这个名字的所有文件
    private var filesByStem: [String: [URL]] = [:]

    private static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private func rebuildRAWIndex() {
        filesByStem = Dictionary(grouping: allImages, by: Self.stem)
    }

    /// 这些文件的同名文件(不含它们自己)。看 JPG 时得到的是 RAW,看 RAW 时得到的是 JPG
    private func siblings(of urls: Set<URL>) -> [URL] {
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

    func revealInFinder(_ indices: Set<Int>) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting(indices.sorted().compactMap { images.indices.contains($0) ? images[$0] : nil })
        #endif
    }

    // MARK: 照片尺寸(瀑布流排版用)

    /// 瀑布流当前渲染的照片序号范围(含屏幕上下的预加载部分);不在瀑布流模式时为 nil。由界面写入
    var waterfallRenderedRange: ClosedRange<Int>?
    /// 已经读到、但暂时没有用到排版里的尺寸(序号 → 比例)。
    ///
    /// 瀑布流是按顺序排的:改动某一张的比例,它后面所有照片的位置都会变。
    /// 如果每读到一点就重排,屏幕里的照片会不停地跳。所以:
    /// - 屏幕下方、还没看到的照片:读到就立即用上(改动只影响更后面的,看不见)。
    /// - 屏幕内或上方的照片:先攒在这里,只在少数几个时机一次性用上(见 settlePendingAspects)。
    private var pendingAspects: [Int: CGFloat] = [:]

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
    private func flushPendingAspects() {
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
    private func loadAspects(restart: Bool = true) {
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

    /// 最近看过 / 预取的主图
    private let mainCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 3   // 当前这张 + 前后各一张;每张约 20–30 MB
        return c
    }()

    /// 加载当前图片和参数。
    /// - 命中缓存直接显示;否则先用缩略图占位,稍等片刻(防抖)再解码大图,
    ///   这样按住方向键快速翻页时不会为每一张都解码。
    /// - 显示完成后预取前后各一张。
    /// - Parameter immediate: 跳过防抖(切换模式时用,立即开始解码)
    private func loadCurrent(immediate: Bool = false) {
        loadTask?.cancel()
        guard let url = current else { mainImage = nil; mainImageURL = nil; meta = []; return }
        let hit = mainCache.object(forKey: url as NSURL)
        if let hit {
            mainImage = hit
        } else if mainImageURL != url || mainImage == nil {
            // 换了一张:先用缩略图占位。还是同一张(比如只是切换模式)就保留已有的图,不要退回成缩略图
            mainImage = ThumbnailCache.shared.bestCached(url)
        }
        mainImageURL = url
        let index = selection

        loadTask = Task {
            let sections = await Task.detached(priority: .userInitiated) { ImageMeta.read(url) }.value
            guard !Task.isCancelled else { return }
            meta = sections

            // 瀑布流模式不显示大图:停留一会儿才预先解码,这样切回普通模式时大图已经就绪
            guard mode == .single else {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                _ = await decodeMain(url)
                return
            }

            if hit == nil {
                if !immediate { try? await Task.sleep(for: .milliseconds(60)) }
                guard !Task.isCancelled else { return }
                let img = await decodeMain(url)
                guard !Task.isCancelled else { return }
                if let img { mainImage = img }
            }

            for neighbor in [index + 1, index - 1] where images.indices.contains(neighbor) {
                guard !Task.isCancelled else { return }
                _ = await decodeMain(images[neighbor])
            }
        }
    }

    /// 解码主图并写入缓存(已缓存则直接返回)
    private func decodeMain(_ url: URL) async -> NSImage? {
        if let hit = mainCache.object(forKey: url as NSURL) { return hit }
        let cg = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                (ImageMeta.isRAW(url) ? ImageMeta.decodeRAW(url, maxPixel: 3000) : nil)
                    ?? ImageMeta.thumbnail(url, maxPixel: 3000)
            }
        }.value
        guard let cg else { return nil }
        noteAspect(url, CGFloat(cg.width) / CGFloat(max(cg.height, 1)))
        let img = NSImage(cgImage: cg, size: .zero)
        mainCache.setObject(img, forKey: url as NSURL)
        return img
    }
}

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
        if let o = p[kCGImagePropertyOrientation] { img.append(MetaRow(name: "方向", value: "\(o)")) }
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
        if let v = exif[kCGImagePropertyExifExposureBiasValue] as? Double { exp.append(MetaRow(name: "曝光补偿", value: String(format: "%+.1f EV", v))) }
        if let v = exif[kCGImagePropertyExifFlash] { exp.append(MetaRow(name: "闪光灯", value: "\(v)") ) }
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

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 用系统 RAW 引擎真正解码(而不是取内嵌 JPG 预览),并缩放到 maxPixel
    static func decodeRAW(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        let longest = max(native.width, native.height)
        if longest > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixel) / longest)) }
        guard let out = filter.outputImage else { return nil }
        defer { ciContext.clearCaches() }   // RAW 解码的中间缓存很大,用完就清
        return ciContext.createCGImage(out, from: out.extent)
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
    nonisolated static let waterfallSizes = [320, 480, 720, 1080, 1600]

    /// 能把 `pixels`(格子最长边的实际像素数)显示清楚的最小一档
    nonisolated static func waterfallSize(forPixels pixels: CGFloat) -> Int {
        waterfallSizes.first { CGFloat($0) >= pixels * 0.9 } ?? waterfallSizes[waterfallSizes.count - 1]
    }

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 256 * 1024 * 1024   // 约 256 MB 像素数据
        return c
    }()
    /// 同时最多读几张。已经开始读的停不下来,所以不能太多:
    /// 太多的话滚到新位置后,要等一大批旧位置的图读完才轮到眼前的
    private let limiter = Limiter(max: max(3, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))

    private func key(_ url: URL, _ size: Int) -> NSString { "\(size)|\(url.path)" as NSString }

    func cached(_ url: URL, size: Int = stripSize) -> NSImage? { cache.object(forKey: key(url, size)) }

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
