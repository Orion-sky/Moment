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
            guard let key = ShortcutStore.normalize(press) else { return .ignored }
            // 瀑布流里 W A S D 固定用来上下左右移动选中的照片,优先于自定义的快捷键
            if store.mode == .waterfall, hasImages,
               let direction: ImageStore.GridDirection = ["w": .up, "a": .left, "s": .down, "d": .right][key] {
                afterUpdate { store.moveInGrid(direction) }
                return .handled
            }
            guard let action = shortcuts.action(for: key) else { return .ignored }
            // 开关类的操作按住不放时不重复触发
            if press.phase == .repeat, !action.repeats { return .handled }
            return perform(action) ? .handled : .ignored
        }
        // 方向键:普通模式是上一张 / 下一张,瀑布流里是按方向移动
        .onKeyPress(.leftArrow) {
            afterUpdate { if store.mode == .waterfall { store.moveInGrid(.left) } else { store.move(-1) } }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            afterUpdate { if store.mode == .waterfall { store.moveInGrid(.right) } else { store.move(1) } }
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard store.mode == .waterfall else { return .ignored }
            afterUpdate { store.moveInGrid(.up) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard store.mode == .waterfall else { return .ignored }
            afterUpdate { store.moveInGrid(.down) }
            return .handled
        }
    }
}
