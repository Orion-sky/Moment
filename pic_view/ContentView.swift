import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var store: ImageStore
    @FocusState private var keyFocus: Bool
    /// 右侧信息栏、底部缩略图条的开关(会记住上次的设置)
    @AppStorage("showInfoPanel") private var showInfo = true
    @AppStorage("showThumbnailStrip") private var showStrip = true
    /// 瀑布流每行显示几张
    @AppStorage("waterfallColumns") private var waterfallColumns = 5

    /// 打开文件夹并扫描到图片后,才显示参数面板和缩略图条
    private var hasImages: Bool { !store.images.isEmpty }

    var body: some View {
        // 缩略图条(120)加分隔线(1)在普通模式下占掉的高度,衔接动画要用
        let _ = (store.stripExtraHeight = showStrip ? 121 : 0)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    // 两种模式共用的底色:主图瞬间移除时不会闪一下
                    Color(nsColor: .underPageBackgroundColor)
                    if store.mode == .waterfall && hasImages {
                        WaterfallView()
                            .transition(.opacity)
                    } else {
                        // 离开时立即移除:飞行中的那张会在同一位置接上
                        ViewerArea()
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hero = store.hero {
                        HeroOverlay(flight: hero) {
                            if store.hero?.id == hero.id { store.hero = nil }
                        }
                        .id(hero.id)
                        // 必须立即出现:否则会被模式切换的动画带上默认的淡入效果,
                        // 照片先消失再慢慢显出来,看起来就是开头闪一下
                        .transition(.identity)
                    }
                }
                .clipped()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { store.photoAreaSize = $0 }
                if hasImages && showInfo {
                    Divider()
                    InfoPanel()
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }
            if hasImages && showStrip && store.mode == .single {
                Divider()
                ThumbnailStrip()
                    .frame(height: 120)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasImages)
        .animation(.easeInOut(duration: 0.2), value: showInfo)
        .animation(.easeInOut(duration: 0.28), value: store.mode)
        .animation(.easeInOut(duration: 0.2), value: showStrip)
        .toolbar {
            if store.mode == .waterfall {
                ToolbarItem {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                        Slider(value: Binding(get: { Double(waterfallColumns) },
                                              set: { waterfallColumns = Int($0.rounded()) }),
                               in: 2...12, step: 1)
                            .controlSize(.small)
                            .frame(width: 90)
                        Image(systemName: "square.grid.4x3.fill")
                        Text("\(waterfallColumns) 列")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .help("瀑布流每行显示的照片数量")
                }
            }
            ToolbarItemGroup {
                Toggle(isOn: $showStrip) {
                    Label("缩略图条", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .help(showStrip ? "隐藏底部缩略图条" : "显示底部缩略图条")
                .disabled(store.mode == .waterfall)
                .keyboardShortcut("t", modifiers: [.command, .option])

                Toggle(isOn: $showInfo) {
                    Label("信息栏", systemImage: "sidebar.right")
                }
                .help(showInfo ? "隐藏右侧信息栏" : "显示右侧信息栏")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            ToolbarItem {
                Picker("格式筛选", selection: $store.filter) {
                    ForEach(FileFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("只显示 JPG / 只显示 RAW / 全部")
            }
            ToolbarItem {
                Picker("显示模式", selection: $store.mode) {
                    Label("普通", systemImage: "photo").tag(ViewMode.single)
                    Label("瀑布流", systemImage: "square.grid.3x3").tag(ViewMode.waterfall)
                }
                .pickerStyle(.segmented)
                .help("切换普通 / 瀑布流模式")
            }
            ToolbarItem {
                Button { store.chooseFolder() } label: { Label("打开文件夹", systemImage: "folder") }
            }
        }
        .navigationTitle(store.current?.lastPathComponent ?? "Moment")
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .onAppear { keyFocus = true }
        .alert("无法删除", isPresented: Binding(get: { store.errorMessage != nil },
                                              set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: store.selection) { keyFocus = true }
        .onKeyPress(.space) {
            // 空格:在普通模式和瀑布流之间切换
            guard hasImages else { return .ignored }
            store.mode = store.mode == .single ? .waterfall : .single
            return .handled
        }
        .onKeyPress(.return) {
            // 瀑布流里按回车打开当前选中的照片
            guard store.mode == .waterfall else { return .ignored }
            store.mode = .single
            return .handled
        }
        .onKeyPress(.leftArrow) { store.move(-1); return .handled }
        .onKeyPress(.rightArrow) { store.move(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-0")) { press in
            switch press.characters {
            case "+", "=": store.zoomRequests.send(1.25)
            case "-": store.zoomRequests.send(0.8)
            default: store.zoomRequests.send(0)
            }
            return .handled
        }
    }
}

/// 模式切换时飞行的那张照片:从起点位置缩放移动到终点位置。
/// 外观在两端都和真实的视图完全一致(没有阴影、圆角随位置过渡、没有回弹),
/// 这样飞到位后换成真实视图时看不出切换。
struct HeroOverlay: View {
    @EnvironmentObject var store: ImageStore
    let flight: HeroFlight
    let onDone: () -> Void
    @State private var arrived = false

    var body: some View {
        let r = arrived ? flight.to : flight.from
        // 格子有 4 的圆角,主图没有
        let inCell = arrived == flight.endsInCell
        // 飞行途中大图解码好了就直接换上,不用等到位后再跳一下
        Image(nsImage: store.mainImage ?? flight.image)
            .resizable()
            .scaledToFill()
            .frame(width: r.width, height: r.height)
            .clipShape(RoundedRectangle(cornerRadius: inCell ? 4 : 0))
            .offset(x: r.minX, y: r.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.3)) { arrived = true } completion: { onDone() }
            }
    }
}

/// 主图显示区
struct ViewerArea: View {
    @EnvironmentObject var store: ImageStore

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = store.mainImage {
                ZoomableImage(image: image)
                    .id(store.current)
                    // 衔接动画进行时由飞行中的那张代替,结束后原位出现
                    .opacity(store.hero == nil ? 1 : 0)
                    .animation(nil, value: store.hero == nil)
            } else if !store.images.isEmpty {
                ProgressView()
            } else if !store.allImages.isEmpty {
                // 文件夹里有照片,但都被当前筛选条件排除了
                ContentUnavailableView {
                    Label("没有 \(store.filter.rawValue) 照片", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("这个文件夹里有 \(store.allImages.count) 张其他格式的照片")
                } actions: {
                    Button("显示全部") { store.filter = .all }
                }
            } else {
                ContentUnavailableView {
                    Label("没有图片", systemImage: "photo.on.rectangle")
                } description: {
                    Text("打开一个文件夹来浏览其中的照片")
                } actions: {
                    Button("打开文件夹…") { store.chooseFolder() }
                }
            }
        }
        .overlay(alignment: .leading) {
            PageArrow(systemImage: "chevron.left", enabled: store.selection > 0) { store.move(-1) }
        }
        .overlay(alignment: .trailing) {
            PageArrow(systemImage: "chevron.right", enabled: store.selection < store.images.count - 1) { store.move(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 主图两侧的翻页热区:鼠标移入才显示箭头
struct PageArrow: View {
    let systemImage: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
                .opacity(hovering && enabled ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: hovering)
        }
        .frame(width: 80)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if enabled { action() } }
        .allowsHitTesting(enabled)
    }
}

/// 右侧参数面板
struct InfoPanel: View {
    @EnvironmentObject var store: ImageStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.current != nil {
                    ForEach(store.meta) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.headline)
                            ForEach(section.rows) { row in
                                HStack(alignment: .top) {
                                    Text(row.name).foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)
                                    Text(row.value).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .font(.callout)
                            }
                        }
                    }
                } else {
                    Text("无参数").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }
}

/// 底部缩略图条,支持水平滚动条
struct ThumbnailStrip: View {
    @EnvironmentObject var store: ImageStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(store.images.indices, id: \.self) { index in
                        ThumbnailCell(url: store.images[index],
                                      selected: store.selected.contains(index),
                                      current: index == store.selection)
                            .id(index)
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                store.click(index, shift: flags.contains(.shift), command: flags.contains(.command))
                            }
                            .contextMenu { PhotoContextMenu(index: index) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)
            .background(WheelToHorizontalScroll())
            // 从瀑布流切回来时,直接定位到当前照片
            .onAppear { proxy.scrollTo(store.selection, anchor: .center) }
            // 切换筛选后列表整体换了,即使选中的序号没变也要重新定位
            .onChange(of: store.listVersion) { proxy.scrollTo(store.selection, anchor: .center) }
            .onChange(of: store.selection) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .background(.bar)
    }
}

/// 缩略图 / 瀑布流共用的右键菜单
struct PhotoContextMenu: View {
    @EnvironmentObject var store: ImageStore
    let index: Int

    var body: some View {
        let targets = store.targets(forContextAt: index)
        Button(targets.count > 1 ? "将 \(targets.count) 张照片移到废纸篓" : "移到废纸篓",
               role: .destructive) { store.trash(targets) }
        // 这些照片里有同名 RAW 时才出现
        let raws = store.rawPairs(for: targets).count
        if raws > 0 {
            Button(targets.count > 1 ? "将 \(targets.count) 张照片连同 \(raws) 个 RAW 一起移到废纸篓"
                                     : "连同 RAW 一起移到废纸篓",
                   role: .destructive) { store.trash(targets, withRAW: true) }
        }
        Divider()
        Button("在访达中显示") { store.revealInFinder(targets) }
    }
}

struct ThumbnailCell: View {
    let url: URL
    let selected: Bool
    /// 是否是主图正在显示的那一张
    let current: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor.opacity(current ? 1 : 0.6), lineWidth: current ? 3 : (selected ? 2 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(selected && !current ? 0.25 : 0)))
        .task(id: url) {
            // 删除后同一个格子会换成另一张图,先换成新图的缓存(没有则清空)
            image = ThumbnailCache.shared.cached(url)
            if image == nil { image = await ThumbnailCache.shared.load(url) }
        }
    }
}
