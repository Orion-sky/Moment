import SwiftUI
import Combine
import AppKit

/// 滚轮缩放 + 拖动平移 + 双击复位的图片视图。
/// 外部用 `.id(url)` 切换图片时,状态会自动复位。
struct ZoomableImage: View {
    let image: NSImage
    /// 右侧被浮动的信息栏盖住的宽度。适应窗口时照片避开这一块;放大后可以延伸到它下面
    var trailingInset: CGFloat = 0
    /// 底部被浮动的缩略图条盖住的高度,同样处理
    var bottomInset: CGFloat = 0
    /// 顶部被工具栏盖住的高度,同样处理
    var topInset: CGFloat = 0
    /// 导航小图是否正在显示(告诉外面,让别的可点区域给它让位)
    var navigatorVisible: Binding<Bool> = .constant(false)
    private let padding = WaterfallLayout.viewerPadding
    private let maxScale: CGFloat = 10

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var throttle = ZoomThrottle()
    /// 滚轮缩放速度,在设置里调
    @AppStorage("wheelZoomSpeed") private var wheelZoomSpeed = 1.0

    private final class ZoomThrottle {
        var budget: CGFloat = 0.25
        var time: TimeInterval = 0
    }
    @State private var pinchStart: CGFloat?
    @EnvironmentObject private var store: ImageStore

    var body: some View {
        GeometryReader { geo in
            // 照片"适应窗口"时所在的区域:整个区域去掉右边被信息栏、底部被缩略图条盖住的部分
            let fit = CGSize(width: max(geo.size.width - trailingInset, 1),
                             height: max(geo.size.height - bottomInset - topInset, 1))
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(padding)
                .frame(width: fit.width, height: fit.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            let start = dragStart ?? offset
                            dragStart = start
                            offset = clamp(CGSize(width: start.width + v.translation.width,
                                                  height: start.height + v.translation.height),
                                           scale: scale, in: fit)
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { scale = 1; offset = .zero } }
                .simultaneousGesture(
                    // 触控板双指捏合
                    MagnifyGesture()
                        .onChanged { v in
                            let start = pinchStart ?? scale
                            pinchStart = start
                            let p = CGPoint(x: v.startLocation.x - fit.width / 2,
                                            y: v.startLocation.y - fit.height / 2)
                            zoom(to: start * v.magnification, at: p, in: fit)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .background(WheelCatcher(ignoreMomentum: true) { dy, precise, p in
                    let step = wheelStep(dy: dy, precise: precise)
                    if step != 0 { zoom(to: scale * exp(step), at: p, in: fit) }
                })
                // 放大后超出"适应区域"的部分不在这里裁掉,而是铺满整个区域再裁:
                // 这样右边、下边超出的部分会延伸到半透明的信息栏和缩略图条下面
                .frame(width: geo.size.width, height: max(geo.size.height - topInset, 1), alignment: .topLeading)
                // 再往上让出工具栏的高度:适应区域从工具栏下方开始,放大后向上超出的部分延伸到工具栏后面
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                .clipped()
                // 放大后在左下角显示导航小图:整张照片加一个框,框住的是当前看到的部分
                .overlay(alignment: .bottomLeading) {
                    if scale > 1.01 {
                        navigator(fit: fit)
                            .padding(14)
                            .padding(.bottom, bottomInset)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: scale > 1.01)
                .onChange(of: scale > 1.01, initial: true) { _, zoomed in navigatorVisible.wrappedValue = zoomed }
                // 键盘 / 菜单缩放:以视图中心为锚点,0 表示复位
                .onReceive(store.zoomRequests) { factor in
                    withAnimation(.easeOut(duration: 0.15)) {
                        if factor == 0 { scale = 1; offset = .zero }
                        else { zoom(to: scale * factor, at: .zero, in: fit) }
                    }
                }
        }
    }

    /// 一次滚轮事件对应的缩放量(对数刻度,0.1 约等于 10%)。
    ///
    /// 不同鼠标差别很大:普通滚轮一格一个事件、数值是 1 左右;
    /// MX Master 这类滚轮轻轻一拨会连发很多个事件,数值还带加速,可以到几十。
    /// 直接按数值缩放的话,拨一下就放大好几倍。所以这里限了两道:
    /// 1. 单个事件最多缩放 8%,不管它报的数值多大;
    /// 2. 单位时间内的缩放总量有上限,事件再密也只能匀速缩放。
    private func wheelStep(dy: CGFloat, precise: Bool) -> CGFloat {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - throttle.time, 0), 1)
        throttle.time = now
        // 设置里的"滚轮缩放速度"(1 是默认)同时放大单次上限和单位时间的额度
        let speed = min(max(wheelZoomSpeed, 0.2), 4)
        // 额度随时间恢复:默认每秒 2.0(持续滚动时大约 1 秒从适应窗口放到最大),最多攒 0.25
        throttle.budget = min(0.25 * speed, throttle.budget + elapsed * 2.0 * speed)

        let cap = 0.08 * speed
        let wanted = min(max(dy * (precise ? 0.01 : 0.04) * speed, -cap), cap)
        let allowed = min(abs(wanted), throttle.budget)
        throttle.budget -= allowed
        return wanted < 0 ? -allowed : allowed
    }

    /// 缩放到 target,保持 p(相对视图中心)下的图像点不动
    private func zoom(to target: CGFloat, at p: CGPoint, in size: CGSize) {
        let newScale = min(max(target, 1), maxScale)
        let ratio = newScale / scale
        let o = CGSize(width: p.x - (p.x - offset.width) * ratio,
                       height: p.y - (p.y - offset.height) * ratio)
        scale = newScale
        offset = clamp(o, scale: newScale, in: size)
    }

    /// 照片在"适应窗口"(1×)时显示出来的大小
    private func baseSize(in fit: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let avail = CGSize(width: max(fit.width - padding * 2, 1), height: max(fit.height - padding * 2, 1))
        let f = min(avail.width / image.size.width, avail.height / image.size.height)
        return CGSize(width: image.size.width * f, height: image.size.height * f)
    }

    /// 导航小图。拖动(或点击)可以直接把视野移到照片的那个位置
    private func navigator(fit: CGSize) -> some View {
        let base = baseSize(in: fit)
        let shown = CGSize(width: max(base.width * scale, 1), height: max(base.height * scale, 1))
        // 小图:最长边 150,按照片比例
        let k = 150 / max(image.size.width, image.size.height, 1)
        let mini = CGSize(width: image.size.width * k, height: image.size.height * k)
        // 当前视野(没被面板遮住的那块区域)落在照片上的范围,换算到小图上
        let left = max(0, (shown.width / 2 - offset.width - fit.width / 2) / shown.width)
        let top = max(0, (shown.height / 2 - offset.height - fit.height / 2) / shown.height)
        let right = min(1, (shown.width / 2 - offset.width + fit.width / 2) / shown.width)
        let bottom = min(1, (shown.height / 2 - offset.height + fit.height / 2) / shown.height)
        let box = CGRect(x: left * mini.width, y: top * mini.height,
                         width: max((right - left) * mini.width, 4), height: max((bottom - top) * mini.height, 4))

        return Image(nsImage: image)
            .resizable()
            .frame(width: mini.width, height: mini.height)
            .overlay {
                // 视野以外的部分压暗
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: mini))
                    path.addRect(box)
                }
                .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(.white, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // 让视野的中心落在鼠标指着的那个点上
                        let u = min(max(v.location.x / mini.width, 0), 1)
                        let w = min(max(v.location.y / mini.height, 0), 1)
                        offset = clamp(CGSize(width: shown.width * (0.5 - u), height: shown.height * (0.5 - w)),
                                       scale: scale, in: fit)
                    }
            )
            .help("拖动来移动视野")
    }

    /// 限制平移,避免图片被拖出视野
    private func clamp(_ o: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > 1, image.size.width > 0, image.size.height > 0 else { return .zero }
        let avail = CGSize(width: max(size.width - padding * 2, 1), height: max(size.height - padding * 2, 1))
        let fit = min(avail.width / image.size.width, avail.height / image.size.height)
        let shown = CGSize(width: image.size.width * fit * scale, height: image.size.height * fit * scale)
        let mx = max(0, (shown.width - size.width) / 2)
        let my = max(0, (shown.height - size.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }
}

/// 捕获所覆盖区域内的滚轮事件,回调 (纵向滚动量, 是否精细滚动, 相对视图中心的鼠标位置)
struct WheelCatcher: NSViewRepresentable {
    /// 非空时,只有按住这些修饰键的滚轮事件才会被捕获,其余照常交给系统(比如正常滚动)
    var requiredModifiers: NSEvent.ModifierFlags = []
    /// 忽略松手后的惯性滚动(仍然吃掉事件,只是不回调)
    var ignoreMomentum = false
    /// 只处理以纵向为主的滚动(鼠标滚轮);横向滑动照常交给系统
    var verticalOnly = false
    let onScroll: (CGFloat, Bool, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.onScroll = onScroll
        v.requiredModifiers = requiredModifiers
        v.ignoreMomentum = ignoreMomentum
        v.verticalOnly = verticalOnly
    }
    static func dismantleNSView(_ v: CatcherView, coordinator: ()) { v.removeMonitor() }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, Bool, CGPoint) -> Void)?
        var requiredModifiers: NSEvent.ModifierFlags = []
        var ignoreMomentum = false
        var verticalOnly = false
        private var monitor: Any?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                guard self.requiredModifiers.isEmpty || event.modifierFlags.contains(self.requiredModifiers) else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local), event.scrollingDeltaY != 0 else { return event }
                if self.verticalOnly, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) { return event }
                if self.ignoreMomentum, !event.momentumPhase.isEmpty { return nil }
                let p = CGPoint(x: local.x - self.bounds.midX, y: local.y - self.bounds.midY)
                self.onScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas, p)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
