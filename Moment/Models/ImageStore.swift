import SwiftUI
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import AppKit

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
    var aspectCache: [URL: CGFloat] = [:]
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
    var waterfallFrames: [CGRect] = []         // 瀑布流此刻的排版(每张照片的位置),按方向移动选中项时用
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
    var aspectKnown: [Bool] = []
    var aspectTask: Task<Void, Never>?
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
        if panel.runModal() == .OK, let url = panel.url {
            // 记住这次授权:以后从访达双击这个文件夹里的照片,就能直接浏览整个文件夹
            FolderAccess.shared.remember(url)
            open(folder: url)
        }
        #endif
    }

    /// 单例:访达把文件交给应用时(双击照片、拖到程序坞图标)要从应用代理里找到它
    static let shared = ImageStore()

    /// 从访达打开:文件夹就直接打开;照片则打开它所在的文件夹并定位到它
    func open(urls: [URL]) {
        guard let url = urls.first else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            // 系统把这个文件夹交给应用时已经给了权限,顺便记住
            FolderAccess.shared.remember(url)
            open(folder: url)
            return
        }
        // 打开单张照片是要看这一张:回到普通模式
        mode = .single
        let parent = url.deletingLastPathComponent()
        // 沙盒下系统只给了这一张照片的权限。要翻看同文件夹的其他照片,需要文件夹的权限:
        // 以前授权过(或它的上级授权过)就直接用,否则问一次并记住
        if FolderAccess.shared.canRead(parent) || FolderAccess.shared.request(for: parent) {
            open(folder: parent, selecting: url)
        } else {
            // 用户没有授权:只显示交过来的这几张
            openOnly(files: urls)
        }
    }

    /// 只显示指定的几个文件(没有所在文件夹的权限时)
    private func openOnly(files: [URL]) {
        scanTask?.cancel()
        stopWatching()
        hiddenFiles = []
        folder = nil
        allImages = files
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        picked = []
        rebuildRAWIndex()
        aspectCache = [:]
        pendingSelect = files.first
        // 只有这几张,不管当前筛选是什么都要显示出来
        if filter != .all { filter = .all } else { applyFilter() }
    }

    // MARK: 监视文件夹的变化

    /// 文件夹内容在应用之外被改动(在访达里删除、移走、拷进新照片,或者存储卡被拔掉)时,
    /// 列表要跟着更新。否则已经不存在的照片还留着缩略图,点上去却什么也打不开
    private var folderMonitor: DispatchSourceFileSystemObject?
    private var refreshTask: Task<Void, Never>?

    private func watch(_ url: URL) {
        stopWatching()
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderMonitor = source
    }

    private func stopWatching() {
        folderMonitor?.cancel()
        folderMonitor = nil
        refreshTask?.cancel()
    }

    /// 变化往往是一连串的(比如拷进一批照片),等它停下来再重新扫描一次
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let folder else { return }
            // 应用自己正在复制 / 移动 / 删除时不插手,那边结束后会自己更新列表
            guard transfer == nil else { scheduleRefresh(); return }
            let scanned = await Task.detached(priority: .utility) { Self.scan(folder) }.value
            // 从列表里移除的照片不要因为重新扫描又回来
            let list = hiddenFiles.isEmpty ? scanned : scanned.filter { !hiddenFiles.contains($0) }
            guard !Task.isCancelled, folder == self.folder, list != allImages else { return }

            let before = Set(allImages)
            let after = Set(list)
            let removed = before.subtracting(after).count
            let added = after.subtracting(before).count
            allImages = list
            picked.formIntersection(after)
            rebuildRAWIndex()
            applyFilter()   // 当前照片还在就保持选中它,不在了就停在文件名相邻的那张

            var parts: [String] = []
            if removed > 0 { parts.append("\(removed) 张照片已被删除或移走") }
            if added > 0 { parts.append("新增 \(added) 张照片") }
            if !parts.isEmpty { edgeNotice = EdgeNotice(text: parts.joined(separator: ","), duration: 3.5) }
        }
    }

    /// 打开文件夹后要选中的照片
    private var pendingSelect: URL?

    /// - Parameter selecting: 打开后选中这张照片(从访达双击照片时)
    func open(folder url: URL, selecting: URL? = nil) {
        _ = url.startAccessingSecurityScopedResource()
        // 换了文件夹,上一个文件夹的缓存用不上了
        if url.standardizedFileURL != folder?.standardizedFileURL { clearCaches() }
        folder = url
        hiddenFiles = []
        watch(url)
        scanTask?.cancel()
        scanTask = Task {
            // 扫描与排序放到后台线程
            let list = await Task.detached(priority: .userInitiated) { Self.scan(url) }.value
            guard !Task.isCancelled else { return }
            allImages = list
            picked = []
            rebuildRAWIndex()
            aspectCache = [:]
            pendingSelect = selecting
            // 要选中的照片被当前的格式筛选挡住了(比如只看 JPG 时双击了一张 RAW):切到"全部"
            if let selecting, !filter.matches(selecting), list.contains(selecting) {
                filter = .all   // 会触发 applyFilter
            } else {
                applyFilter()
            }
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
        let keep = pendingSelect ?? current
        pendingSelect = nil
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

    /// 翻到头 / 尾时的提示,显示一小会儿后自动消失
    @Published var edgeNotice: EdgeNotice?

    struct EdgeNotice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// 显示多久(秒)
        var duration: Double = 1.2
    }

    /// 最近一次选中项变化是不是鼠标点出来的(缩略图条据此决定要不要重新居中)。不触发刷新
    private(set) var selectionByClick = false

    func move(_ delta: Int) {
        guard !images.isEmpty else { return }
        selectionByClick = false
        let target = selection + delta
        // 已经在头或尾还继续翻:给个提示,不然按了没反应会以为是卡住了
        if target < 0 { edgeNotice = EdgeNotice(text: "已经是第一张") }
        else if target > images.count - 1 { edgeNotice = EdgeNotice(text: "已经是最后一张") }
        else if edgeNotice != nil { edgeNotice = nil }
        selection = min(max(target, 0), images.count - 1)
        selected = [selection]
        anchor = selection
    }

    nonisolated enum GridDirection { case up, down, left, right }

    /// 瀑布流里按方向移动选中项。
    /// 上下是同一列里相邻的那张;左右按"阅读顺序"(见 `readingOrder`)走到前一张 / 后一张,
    /// 走到一行的末尾会自动换到下一行的开头
    func moveInGrid(_ direction: GridDirection) {
        let frames = waterfallFrames
        guard frames.count == images.count, frames.indices.contains(selection) else { return }
        var target: Int?
        switch direction {
        case .up, .down:
            // 同一列里的照片是按序号从上往下排的
            let column = frames.indices.filter { abs(frames[$0].minX - frames[selection].minX) < 0.5 }
            if let place = column.firstIndex(of: selection) {
                let next = place + (direction == .up ? -1 : 1)
                if column.indices.contains(next) { target = column[next] }
            }
            // 最后一行参差不齐:这一列下面已经没有照片时,往下直接跳到最后一张
            if direction == .down, target == nil, let last = Self.readingOrder(frames).last, last != selection {
                target = last
            }
        case .left, .right:
            let order = Self.readingOrder(frames)
            if let place = order.firstIndex(of: selection) {
                let next = place + (direction == .left ? -1 : 1)
                if order.indices.contains(next) { target = order[next] }
            }
        }
        selectionByClick = false
        guard let target else {
            let text = switch direction {
            case .up: "已经是最上面一张"
            case .down, .right: "已经是最后一张"
            case .left: "已经是第一张"
            }
            edgeNotice = EdgeNotice(text: text)
            return
        }
        if edgeNotice != nil { edgeNotice = nil }
        selection = target
        selected = [target]
        anchor = target
    }

    /// 瀑布流的阅读顺序:一行一行从左往右。
    ///
    /// 瀑布流的照片高低不齐,没有现成的行,这里这样分行:
    /// 每列排在最前面、还没分进行的那张照片里,中线最高的那张定出这一行的水平线;
    /// 每一列里顶边在这条线以上的那张照片都属于这一行,行内按列从左到右。
    /// 每一行至少分走一张,所以每张照片都恰好出现一次,最后一行最右边那张就是"最后一张"
    nonisolated static func readingOrder(_ frames: [CGRect]) -> [Int] {
        // 按列分组(同一列 x 相同),列内是按序号从上往下排的
        var byColumn: [CGFloat: [Int]] = [:]
        for i in frames.indices { byColumn[(frames[i].minX * 2).rounded() / 2, default: []].append(i) }
        let columns = byColumn.keys.sorted().map { byColumn[$0]! }
        var heads = [Int](repeating: 0, count: columns.count)
        var order: [Int] = []
        order.reserveCapacity(frames.count)
        while order.count < frames.count {
            var line = CGFloat.infinity
            for c in columns.indices where heads[c] < columns[c].count {
                line = min(line, frames[columns[c][heads[c]]].midY)
            }
            for c in columns.indices where heads[c] < columns[c].count {
                let i = columns[c][heads[c]]
                if frames[i].minY <= line { order.append(i); heads[c] += 1 }
            }
        }
        return order
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

    /// 从列表里移除的照片:只是不再显示,文件还在原处。重新打开文件夹后恢复
    private var hiddenFiles: Set<URL> = []

    /// 把指定照片从列表里移除(不删除文件)
    func removeFromList(_ indices: Set<Int>) {
        let files = Set(urls(at: indices))
        guard !files.isEmpty else { return }
        hiddenFiles.formUnion(files)
        dropFromLists(files)
        edgeNotice = EdgeNotice(text: "已从列表中移除 \(files.count) 张照片,文件仍在原处", duration: 2.5)
    }

    /// 这些文件不再显示了(删除、移走或从列表里移除):从各个列表里去掉,并停在原位置附近
    func dropFromLists(_ urls: Set<URL>) {
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
    @Published var picked: Set<URL> = []
    /// 正在复制 / 移动时的进度
    @Published var transfer: TransferProgress?


    // MARK: 同名文件(RAW + JPG 成对拍摄)

    /// 文件名(不含扩展名、不分大小写)→ 叫这个名字的所有文件
    var filesByStem: [String: [URL]] = [:]


    // MARK: 照片尺寸(瀑布流排版用)

    /// 瀑布流当前渲染的照片序号范围(含屏幕上下的预加载部分);不在瀑布流模式时为 nil。由界面写入
    var waterfallRenderedRange: ClosedRange<Int>?
    /// 已经读到、但暂时没有用到排版里的尺寸(序号 → 比例)。
    ///
    /// 瀑布流是按顺序排的:改动某一张的比例,它后面所有照片的位置都会变。
    /// 如果每读到一点就重排,屏幕里的照片会不停地跳。所以:
    /// - 屏幕下方、还没看到的照片:读到就立即用上(改动只影响更后面的,看不见)。
    /// - 屏幕内或上方的照片:先攒在这里,只在少数几个时机一次性用上(见 settlePendingAspects)。
    var pendingAspects: [Int: CGFloat] = [:]


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

    /// 清空图片缓存(缩略图和预取的主图)。换文件夹时用:上一个文件夹的缓存已经用不上了
    func clearCaches() {
        ThumbnailCache.shared.removeAll()
        mainCache.removeAllObjects()
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
