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
    /// 缩略图条面板的高度:上留白 8 + 缩略图 84 + 到滚动条的间距 6 + 滚动条 5 + 下留白 4
    private let stripHeight: CGFloat = 107

    /// 给工具栏控件用的绑定:读是即时的,写推到下一轮主线程循环。
    ///
    /// 工具栏里的 Picker / Toggle 会在界面刷新的过程中把新值写回来。
    /// 而改模式、改筛选会连带更新 ImageStore 里的很多项(照片列表、选中项、主图、尺寸……),
    /// 这些更新如果发生在刷新途中,SwiftUI 就会逐项警告"在界面更新过程中发布变化"。
    private func deferred<Value>(_ keyPath: ReferenceWritableKeyPath<ImageStore, Value>) -> Binding<Value> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { value in DispatchQueue.main.async { store[keyPath: keyPath] = value } }
        )
    }

    /// 执行一个快捷键操作;当前模式下不适用时返回 false
    private func perform(_ action: ShortcutAction) -> Bool {
        // 先判断当前能不能做(要立即回答"这个键有没有被处理")
        switch action {
        case .previous, .next, .toggleStrip:
            // 翻页在普通模式下等同于 ← / →;瀑布流模式本来就没有缩略图条
            guard store.mode == .single else { return false }
        case .toggleMode, .toggleCulling, .togglePick:
            guard hasImages else { return false }
        case .toggleFullScreen:
            guard NSApp.keyWindow != nil else { return false }
        case .toggleInfo, .zoomIn, .zoomOut, .zoomReset:
            break
        }
        // 真正的改动推到下一轮:按键回调是在界面刷新的过程中被调用的,
        // 在这里直接改 ImageStore 会触发"在界面更新过程中发布变化"的警告
        afterUpdate {
            switch action {
            case .previous: store.move(-1)
            case .next: store.move(1)
            case .toggleMode: store.mode = store.mode == .single ? .waterfall : .single
            case .toggleInfo: showInfo.toggle()
            case .toggleStrip: showStrip.toggle()
            case .toggleCulling: store.culling.toggle()
            case .togglePick:
                // 不在筛选模式时,先进入再标记:按一下就开始挑片
                if !store.culling { store.culling = true }
                store.togglePick()
            case .toggleFullScreen: NSApp.keyWindow?.toggleFullScreen(nil)
            case .zoomIn: store.zoomRequests.send(1.25)
            case .zoomOut: store.zoomRequests.send(0.8)
            case .zoomReset: store.zoomRequests.send(0)
            }
        }
        return true
    }

    /// 等这一轮界面刷新结束后再执行
    private func afterUpdate(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    /// 窗口内容。铺满整个窗口,包括工具栏后面;topInset 是工具栏占的高度
    @ViewBuilder private func content(topInset: CGFloat) -> some View {
        let _ = (store.topInset = topInset)
        // 缩略图条加上下留白在普通模式下盖住的高度,衔接动画要用
        let _ = (store.stripExtraHeight = showStrip ? stripHeight + 16 : 0)
        // 信息栏浮在照片区域上面,这是它盖住的宽度(面板 280 + 右边留白 8)
        let infoInset: CGFloat = hasImages && showInfo ? 288 : 0
        let _ = (store.trailingInset = infoInset)
        // 缩略图条也浮在照片区域上面,这是它盖住的高度(面板 + 上下留白各 8)
        let stripInset: CGFloat = hasImages && showStrip && store.mode == .single ? stripHeight + 16 : 0
        ZStack {
            ZStack {
                ZStack {
                    // 两种模式共用的底色:主图瞬间移除时不会闪一下
                    Color(nsColor: .underPageBackgroundColor)
                    if store.mode == .waterfall && hasImages {
                        // 瀑布流不能被信息栏挡住,让出右边
                        WaterfallView(topInset: topInset)
                            .padding(.trailing, infoInset)
                            .transition(.opacity)
                    } else {
                        // 离开时立即移除:飞行中的那张会在同一位置接上
                        ViewerArea(trailingInset: infoInset, bottomInset: stripInset, topInset: topInset)
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hero = store.hero {
                        HeroOverlay(flight: hero) {
                            // 动画的完成回调可能发生在界面刷新途中,推到下一轮再改
                            DispatchQueue.main.async {
                                if store.hero?.id == hero.id { store.hero = nil }
                            }
                        }
                        .id(hero.id)
                        // 必须立即出现:否则会被模式切换的动画带上默认的淡入效果,
                        // 照片先消失再慢慢显出来,看起来就是开头闪一下
                        .transition(.identity)
                    }
                }
                .clipped()
                .overlay(alignment: .top) {
                    if store.culling && hasImages {
                        CullingBar()
                            .padding(.top, 10 + topInset)
                            .padding(.trailing, infoInset)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: store.culling)
                .overlay {
                    // 翻到第一张 / 最后一张时的提示,在没被面板遮住的区域里居中
                    if let notice = store.edgeNotice {
                        Text(notice.text)
                            .font(.title3.weight(.medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.trailing, infoInset)
                            .padding(.bottom, stripInset)
                            .padding(.top, topInset)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            // 每次提示(包括按住不放连续触发)都重新计时,到时间后消失
                            .task(id: notice.id) {
                                try? await Task.sleep(for: .seconds(notice.duration))
                                if !Task.isCancelled, store.edgeNotice?.id == notice.id { store.edgeNotice = nil }
                            }
                    }
                }
                .animation(.easeOut(duration: 0.18), value: store.edgeNotice?.text)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { store.photoAreaSize = $0 }
                if hasImages && showInfo {
                    // 液态玻璃:信息栏浮在照片区域上面。照片放大后会延伸到它下面,透过玻璃能看到
                    InfoPanel()
                        .frame(width: 280)
                        .clipShape(.rect(cornerRadius: panelRadius))
                        .glassEffect(.regular, in: .rect(cornerRadius: panelRadius))
                        .padding(.trailing, 8)
                        // 上面停在工具栏下方
                        .padding(.top, topInset > 0 ? topInset + 2 : 8)
                        // 缩略图条在的时候,信息栏停在它上方,两块面板不重叠
                        .padding(.bottom, stripInset > 0 ? stripInset : 8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if stripInset > 0 {
                // 缩略图条同样浮在照片区域上面,照片放大后会延伸到它下面
                ThumbnailStrip()
                    .frame(height: stripHeight)
                    .clipShape(.rect(cornerRadius: panelRadius))
                    .glassEffect(.regular, in: .rect(cornerRadius: panelRadius))
                    .padding(8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 照片区域和玻璃面板共用同一块底色,面板才像是浮在上面
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    var body: some View {
        GeometryReader { proxy in
            // 沉浸式:内容延伸到工具栏后面。先量出工具栏的高度,
            // 适应窗口时照片避开它,放大后可以延伸到它下面
            content(topInset: proxy.safeAreaInsets.top)
                .ignoresSafeArea(.container, edges: .top)
        }
        // 工具栏不要自己的底色,只留浮着的玻璃按钮
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // 全屏时工具栏没法做成透明的,改为自动隐藏,照片铺满整个屏幕
        .background(FullScreenToolbarAutoHide())
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
                Picker("显示模式", selection: deferred(\.mode)) {
                    Label("普通", systemImage: "photo").tag(ViewMode.single)
                    Label("瀑布流", systemImage: "square.grid.3x3").tag(ViewMode.waterfall)
                }
                .pickerStyle(.segmented)
                .help("切换普通 / 瀑布流模式")

                Picker("格式筛选", selection: deferred(\.filter)) {
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
                Toggle(isOn: deferred(\.culling)) {
                    Label("筛选模式", systemImage: "checkmark.circle")
                }
                .help(store.culling ? "退出筛选模式" : "筛选模式:标记照片,再复制或移动到别的文件夹")

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
        .alert(store.alertTitle, isPresented: Binding(get: { store.errorMessage != nil },
                                              set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: store.selection) { keyFocus = true }
        .onKeyPress(.escape) {
            // 筛选模式下,Esc 先退出筛选模式(全屏时也是先退这个,再按一次才退出全屏)
            if store.culling {
                afterUpdate { store.culling = false }
                return .handled
            }
            // 全屏时按 Esc 退出全屏(主界面拿着键盘焦点,系统默认的这个行为到不了窗口)
            guard let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) else { return .ignored }
            window.toggleFullScreen(nil)
            return .handled
        }
        .onKeyPress(.return) {
            // 瀑布流里按回车打开当前选中的照片
            guard store.mode == .waterfall else { return .ignored }
            afterUpdate { store.mode = .single }
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
        .onKeyPress(.leftArrow) { afterUpdate { store.move(-1) }; return .handled }
        .onKeyPress(.rightArrow) { afterUpdate { store.move(1) }; return .handled }
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
    /// 右侧被信息栏盖住的宽度、底部被缩略图条盖住的高度
    var trailingInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// 顶部被工具栏盖住的高度
    var topInset: CGFloat = 0
    /// 放大时左下角有导航小图
    @State private var navigatorVisible = false

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = store.mainImage {
                ZoomableImage(image: image, trailingInset: trailingInset, bottomInset: bottomInset, topInset: topInset,
                              navigatorVisible: $navigatorVisible)
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
        .overlay(alignment: .topLeading) {
            // 筛选模式下,当前照片被标记时在角上显示(左下角留给放大时的导航小图)
            if store.culling, let url = store.current, store.picked.contains(url), store.hero == nil {
                Label("已标记", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.green.opacity(0.5)), in: .capsule)
                    .padding(14)
                    .padding(.top, topInset)
            }
        }
        .overlay(alignment: .leading) {
            // 左侧的翻页热区是从上到下一整条,会盖住左下角的导航小图、把它的拖动截走。
            // 小图显示时,热区让出下面这一段(小图最高 150,加上下留白)
            PageArrow(systemImage: "chevron.left", enabled: store.selection > 0) { store.move(-1) }
                .padding(.bottom, bottomInset + (navigatorVisible && store.mainImage != nil ? 178 : 0))
                .padding(.top, topInset)
        }
        .overlay(alignment: .trailing) {
            PageArrow(systemImage: "chevron.right", enabled: store.selection < store.images.count - 1) { store.move(1) }
                .padding(.trailing, trailingInset)
                .padding(.bottom, bottomInset)
                .padding(.top, topInset)
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
    @State private var wheel = WheelTarget()
    /// 出现后还欠一次"居中到当前照片"
    @State private var pendingCenter = true

    /// 连续滚轮时累计的目标位置(滚动位置的回报有延迟,连续几格要在上一格的目标上继续加)
    private final class WheelTarget {
        var x: CGFloat = 0
        var time: TimeInterval = 0
    }

    private var maxOffset: CGFloat { max(0, contentWidth - viewWidth) }

    /// 鼠标滚轮(纵向)转成横向滚动。
    /// 和点击、拖动滚动条走同一个滚动位置,这样滚完再点照片时不会从旧位置跳一下
    private func wheelScroll(dy: CGFloat, precise: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let base = now - wheel.time < 0.15 ? wheel.x : offsetX
        let x = min(max(base - (precise ? dy : dy * 12), 0), maxOffset)
        wheel.x = x
        wheel.time = now
        position.scrollTo(x: x)
    }

    /// 选中项变化后滚动缩略图条。
    /// 点击选中的:它本来就在眼前,只在被边缘挡住时挪到刚好露出,不重新居中(否则会跳一下)。
    /// 键盘翻页的:居中显示。
    private func reveal(_ index: Int, minimal: Bool, animated: Bool = true) {
        let left = 10 + CGFloat(index) * 92
        var x: CGFloat
        if !minimal {
            x = left + 42 - viewWidth / 2
        } else if left < offsetX {
            x = left - 10
        } else if left + 84 > offsetX + viewWidth {
            x = left + 84 + 10 - viewWidth
        } else {
            return
        }
        x = min(max(x, 0), maxOffset)
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { position.scrollTo(x: x) }
        } else {
            // 直接跳过去时先把要渲染的范围也挪过去,不用等滚动位置报回来
            offsetX = x
            position.scrollTo(x: x)
        }
    }

    /// 内容总宽度:每格 84、间距 8、两端各留 10。直接算出来,比懒加载列表的估算值准
    private var contentWidth: CGFloat {
        let n = CGFloat(store.images.count)
        return n * 84 + max(n - 1, 0) * 8 + 20
    }

    /// 当前要渲染的格子:屏幕内的,加上左右各多出几格。
    /// 系统的懒加载列表会把滚过的格子(连同它们的图片和图层)一直留着,滚得越多占得越多;
    /// 这里自己算范围,滚走的格子直接销毁,内存只和屏幕上有几格有关
    private var visibleRange: Range<Int> {
        let count = store.images.count
        guard count > 0 else { return 0..<0 }
        let width = viewWidth > 0 ? viewWidth : 1600   // 还没量到宽度时先按一屏估
        let first = Int(((offsetX - 10) / 92).rounded(.down)) - 4
        let last = Int(((offsetX + width - 10) / 92).rounded(.up)) + 4
        let lower = min(max(first, 0), count)
        return lower..<min(max(last, lower), count)
    }

    var body: some View {
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    ForEach(visibleRange, id: \.self) { index in
                        ThumbnailCell(url: store.images[index],
                                      picked: store.picked.contains(store.images[index]),
                                      selected: store.selected.contains(index),
                                      current: index == store.selection)
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                store.click(index, shift: flags.contains(.shift), command: flags.contains(.command))
                            }
                            .contextMenu { PhotoContextMenu(index: index) }
                            .offset(x: 10 + CGFloat(index) * 92, y: 8)
                    }
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // 系统滚动条(接了鼠标时是又粗又带底槽的那种)藏起来,换成下面自己画的细滚动条
            // 必须用 .never:.hidden 在接了鼠标时系统仍会把滚动条显示出来
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.x, $0.containerSize.width] } action: { _, v in
                offsetX = v[0]
                viewWidth = v[1]
                // 刚出现时还不知道宽度,没法居中;量到宽度后补上
                if pendingCenter, v[1] > 0 {
                    pendingCenter = false
                    reveal(store.selection, minimal: false, animated: false)
                }
            }
            .overlay(alignment: .bottom) {
                SlimScrollbar(offset: offsetX, contentLength: contentWidth, viewLength: viewWidth) { x in
                    position.scrollTo(x: x)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            .background(WheelCatcher(verticalOnly: true) { dy, precise, _ in
                wheelScroll(dy: dy, precise: precise)
            })
            // 从瀑布流切回来时,直接定位到当前照片(宽度量到之后执行,见上面)
            .onAppear { pendingCenter = true }
            // 切换筛选后列表整体换了,即使选中的序号没变也要重新定位
            .onChange(of: store.listVersion) {
                if viewWidth > 0 { reveal(store.selection, minimal: false, animated: false) } else { pendingCenter = true }
            }
            .onChange(of: store.selection) { _, new in
                reveal(new, minimal: store.selectionByClick)
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
        // 这些照片有同名文件时才出现:看 JPG 时是带上 RAW,看 RAW 时是带上 JPG
        let pairs = store.pairs(for: targets)
        let pairsText = ImageStore.describe(pairs, of: store.urls(at: targets))
        if !pairs.isEmpty {
            Button(targets.count > 1 ? "将 \(targets.count) 张照片连同 \(pairsText) 一起移到废纸篓"
                                     : "连同 \(pairsText) 一起移到废纸篓",
                   role: .destructive) { store.trash(targets, withPairs: true) }
        }
        Divider()
        Button("在访达中显示") { store.revealInFinder(targets) }
    }
}

/// 被标记照片右上角的绿色对勾
struct PickBadge: View {
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// 操作条上的文字按钮:可点时是清楚的前景色,鼠标移上去有底色,不可点时才变淡。
/// (系统的无边框按钮默认是灰色文字,看起来像不能点)
struct BarButtonStyle: ButtonStyle {
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration, color: color) }

    private struct Content: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .fontWeight(.medium)
                .foregroundStyle(color.opacity(isEnabled ? 1 : 0.35))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.22 : hovering ? 0.12 : 0),
                            in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

/// 筛选模式的操作条:浮在照片区域顶部
struct CullingBar: View {
    @EnvironmentObject var store: ImageStore
    @AppStorage("cullingIncludeRAW") private var includePairs = false
    @State private var confirmingDelete = false

    var body: some View {
        let count = store.picked.count
        let pairs = store.pickedPairs
        let withPairs = includePairs && !pairs.isEmpty
        let pairsText = ImageStore.describe(pairs, of: store.picked)
        HStack(spacing: 6) {
            if let transfer = store.transfer {
                ProgressView(value: Double(transfer.done), total: Double(max(transfer.total, 1)))
                    .frame(width: 160)
                Text("正在\(transfer.verb) \(transfer.done) / \(transfer.total)")
                    .monospacedDigit()
            } else {
                Text(count == 0 ? "按 \(ShortcutStore.displayName(ShortcutStore.shared.key(for: .togglePick))) 标记照片"
                                : "已标记 \(count) 张")
                    .monospacedDigit()
                    .foregroundStyle(count == 0 ? .secondary : .primary)

                Divider().frame(height: 16)

                Button("全选") { store.pickAll() }
                Button("反选") { store.invertPicks() }
                Button("清除") { store.clearPicks() }
                    .disabled(count == 0)

                if !pairs.isEmpty {
                    Divider().frame(height: 16)
                    Toggle("连同 \(pairsText)", isOn: $includePairs)
                        .toggleStyle(.checkbox)
                        // 鼠标停在上面可以看到具体会带上哪些文件
                        .help("复制 / 移动 / 删除时会带上这些还没标记的同名文件:\n"
                              + pairs.map(\.lastPathComponent).sorted().prefix(12).joined(separator: "\n")
                              + (pairs.count > 12 ? "\n…共 \(pairs.count) 个" : ""))
                }

                Divider().frame(height: 16)

                Button("复制到…") { store.transferPicked(.copy, includePairs: includePairs && !pairs.isEmpty) }
                    .disabled(count == 0)
                Button("移动到…") { store.transferPicked(.move, includePairs: includePairs && !pairs.isEmpty) }
                    .disabled(count == 0)

                Divider().frame(height: 16)

                Button("删除", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(BarButtonStyle(color: .red))
                    .disabled(count == 0)
                    .help("把标记的照片移到废纸篓")
            }
        }
        .font(.callout)
        .buttonStyle(BarButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        // 一次删很多张,先确认一下(数量和是否带同名文件都写清楚)
        .confirmationDialog(
            withPairs ? "将标记的 \(count) 张照片连同 \(pairsText) 移到废纸篓?"
                      : "将标记的 \(count) 张照片移到废纸篓?",
            isPresented: $confirmingDelete
        ) {
            Button("移到废纸篓", role: .destructive) { store.trashPicked(includePairs: withPairs) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可以在废纸篓里恢复。")
        }
    }
}

struct ThumbnailCell: View {
    let url: URL
    var picked = false
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
        .overlay(alignment: .topTrailing) {
            if picked { PickBadge(size: 16).padding(4) }
        }
        .task(id: url) {
            // 删除后同一个格子会换成另一张图,先换成新图的缓存(没有则清空)
            image = ThumbnailCache.shared.cached(url)
            if image == nil { image = await ThumbnailCache.shared.load(url) }
        }
    }
}
