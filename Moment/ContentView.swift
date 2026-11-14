import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var store: ImageStore
    @FocusState private var keyFocus: Bool
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// 右侧信息栏、底部缩略图条的开关(会记住上次的设置)
    @AppStorage("showInfoPanel") private var showInfo = true
    @AppStorage("showThumbnailStrip") private var showStrip = true
    /// 外观:跟随系统 / 浅色 / 深色
    @AppStorage("appearance") private var appearance = AppAppearance.system
    /// 瀑布流每行显示几张
    @AppStorage("waterfallColumns") private var waterfallColumns = 5

    /// 打开文件夹并扫描到图片后,才显示参数面板和缩略图条
    private var hasImages: Bool { !store.images.isEmpty }
    private let panelRadius: CGFloat = 16

    /// 执行一个快捷键操作;当前模式下不适用时返回 false
    private func perform(_ action: ShortcutAction) -> Bool {
        switch action {
        case .previous, .next:
            // 普通模式下等同于 ← / →
            guard store.mode == .single else { return false }
            store.move(action == .previous ? -1 : 1)
        case .toggleMode:
            guard hasImages else { return false }
            store.mode = store.mode == .single ? .waterfall : .single
        case .toggleInfo:
            showInfo.toggle()
        case .toggleStrip:
            // 瀑布流模式本来就没有缩略图条
            guard store.mode == .single else { return false }
            showStrip.toggle()
        case .zoomIn: store.zoomRequests.send(1.25)
        case .zoomOut: store.zoomRequests.send(0.8)
        case .zoomReset: store.zoomRequests.send(0)
        }
        return true
    }

    var body: some View {
        // 缩略图条(116)加上下留白(8 + 8)在普通模式下占掉的高度,衔接动画要用
        let _ = (store.stripExtraHeight = showStrip ? 132 : 0)
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
                    // 液态玻璃:信息栏是浮在背景上的一块圆角玻璃面板
                    InfoPanel()
                        .frame(width: 280)
                        .clipShape(.rect(cornerRadius: panelRadius))
                        .glassEffect(.regular, in: .rect(cornerRadius: panelRadius))
                        .padding([.top, .bottom, .trailing], 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if hasImages && showStrip && store.mode == .single {
                ThumbnailStrip()
                    .frame(height: 116)
                    .clipShape(.rect(cornerRadius: panelRadius))
                    .glassEffect(.regular, in: .rect(cornerRadius: panelRadius))
                    .padding(8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 照片区域和玻璃面板共用同一块底色,面板才像是浮在上面
        .background(Color(nsColor: .underPageBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: hasImages)
        .animation(.easeInOut(duration: 0.2), value: showInfo)
        .animation(.easeInOut(duration: 0.28), value: store.mode)
        .animation(.easeInOut(duration: 0.2), value: showStrip)
        .onAppear { appearance.apply() }
        .onChange(of: appearance) { appearance.apply() }
        .toolbar {
            // 左侧:打开文件夹
            ToolbarItem(placement: .navigation) {
                Button { store.chooseFolder() } label: { Label("打开文件夹", systemImage: "folder") }
                    .help("打开文件夹…")
            }

            // 中间:怎么看(模式、筛选;瀑布流时再加列数)
            ToolbarItemGroup(placement: .principal) {
                Picker("显示模式", selection: $store.mode) {
                    Label("普通", systemImage: "photo").tag(ViewMode.single)
                    Label("瀑布流", systemImage: "square.grid.3x3").tag(ViewMode.waterfall)
                }
                .pickerStyle(.segmented)
                .help("切换普通 / 瀑布流模式")

                Picker("格式筛选", selection: $store.filter) {
                    ForEach(FileFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("只显示 JPG / 只显示 RAW / 全部")

                if store.mode == .waterfall {
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

            // 右侧:面板开关和外观(信息栏开关正好在信息栏上方)
            ToolbarItemGroup(placement: .primaryAction) {
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

                Menu {
                    Picker("外观", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("外观", systemImage: appearance == .dark ? "moon.fill"
                                              : appearance == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                }
                .help("外观:跟随系统 / 浅色 / 深色")
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
        .onKeyPress(.escape) {
            // 全屏时按 Esc 退出全屏(主界面拿着键盘焦点,系统默认的这个行为到不了窗口)
            guard let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) else { return .ignored }
            window.toggleFullScreen(nil)
            return .handled
        }
        .onKeyPress(.return) {
            // 瀑布流里按回车打开当前选中的照片
            guard store.mode == .waterfall else { return .ignored }
            store.mode = .single
            return .handled
        }
        // 可自定义的快捷键(在"设置"里修改),见 ShortcutStore
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard let key = ShortcutStore.normalize(press),
                  let action = shortcuts.action(for: key) else { return .ignored }
            // 开关类的操作按住不放时不重复触发
            if press.phase == .repeat, !action.repeats { return .handled }
            return perform(action) ? .handled : .ignored
        }
        .onKeyPress(.leftArrow) { store.move(-1); return .handled }
        .onKeyPress(.rightArrow) { store.move(1); return .handled }
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
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                // 液态玻璃按钮:会折射后面的照片,按下时有反馈
                .glassEffect(.regular.interactive(), in: .circle)
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
    @State private var position = ScrollPosition()
    /// [滚动位置, 内容高度, 可见高度]
    @State private var metrics: [CGFloat] = [0, 0, 0]

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
        // 和缩略图条一样:藏起系统滚动条,换成细滚动条(内容一屏放得下时不显示)
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: [CGFloat].self) {
            [$0.contentOffset.y, $0.contentSize.height, $0.containerSize.height]
        } action: { _, new in
            metrics = new
        }
        .overlay(alignment: .trailing) {
            SlimScrollbar(axis: .vertical, offset: metrics[0], contentLength: metrics[1], viewLength: metrics[2]) { y in
                position.scrollTo(y: y)
            }
            .padding(.vertical, 12)
            .padding(.trailing, 3)
        }
    }
}

/// 底部缩略图条,支持水平滚动条
struct ThumbnailStrip: View {
    @EnvironmentObject var store: ImageStore
    @State private var position = ScrollPosition()
    @State private var offsetX: CGFloat = 0
    @State private var viewWidth: CGFloat = 0

    /// 内容总宽度:每格 84、间距 8、两端各留 10。直接算出来,比懒加载列表的估算值准
    private var contentWidth: CGFloat {
        let n = CGFloat(store.images.count)
        return n * 84 + max(n - 1, 0) * 8 + 20
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
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
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // 系统滚动条(接了鼠标时是又粗又带底槽的那种)藏起来,换成下面自己画的细滚动条
            // 必须用 .never:.hidden 在接了鼠标时系统仍会把滚动条显示出来
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.x, $0.containerSize.width] } action: { _, v in
                offsetX = v[0]
                viewWidth = v[1]
            }
            .overlay(alignment: .bottom) {
                SlimScrollbar(offset: offsetX, contentLength: contentWidth, viewLength: viewWidth) { x in
                    position.scrollTo(x: x)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            }
            .background(WheelToHorizontalScroll())
            // 从瀑布流切回来时,直接定位到当前照片
            .onAppear { proxy.scrollTo(store.selection, anchor: .center) }
            // 切换筛选后列表整体换了,即使选中的序号没变也要重新定位
            .onChange(of: store.listVersion) { proxy.scrollTo(store.selection, anchor: .center) }
            .onChange(of: store.selection) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

/// 细的圆头滚动条:平时很淡,鼠标移上去或拖动时变粗变深;可以拖动
struct SlimScrollbar: View {
    var axis: Axis = .horizontal
    let offset: CGFloat
    let contentLength: CGFloat
    let viewLength: CGFloat
    let scrollTo: (CGFloat) -> Void

    @State private var hovering = false
    @State private var dragStart: CGFloat?

    /// 可抓取区域的厚度(看到的细条比它细)
    private let grip: CGFloat = 10

    var body: some View {
        let horizontal = axis == .horizontal
        GeometryReader { geo in
            let track = horizontal ? geo.size.width : geo.size.height
            let scrollable = contentLength - viewLength
            if scrollable > 1, track > 0, viewLength > 0 {
                let thumb = min(max(36, track * viewLength / contentLength), track)
                let travel = max(track - thumb, 1)
                let pos = min(max(offset / scrollable, 0), 1) * travel
                let active = hovering || dragStart != nil
                let thickness: CGFloat = active ? 7 : 5
                // 透明的抓取区域里贴边放一根细条
                ZStack(alignment: horizontal ? .bottom : .trailing) {
                    Color.clear
                    Capsule()
                        .fill(.primary.opacity(active ? 0.75 : 0.5))
                        .frame(width: horizontal ? thumb : thickness, height: horizontal ? thickness : thumb)
                        .animation(.easeOut(duration: 0.12), value: active)
                }
                .frame(width: horizontal ? thumb : grip, height: horizontal ? grip : thumb)
                .contentShape(Rectangle())
                .gesture(
                    // 用全局坐标:滑块自己在动,用它自身的坐标量出来的拖动距离会不准
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in
                            let start = dragStart ?? offset
                            dragStart = start
                            let moved = horizontal ? v.translation.width : v.translation.height
                            scrollTo(min(max(start + moved / travel * scrollable, 0), scrollable))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .offset(x: horizontal ? pos : 0, y: horizontal ? 0 : pos)
            }
        }
        .frame(width: horizontal ? nil : grip, height: horizontal ? grip : nil)
        .onHover { hovering = $0 }
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
