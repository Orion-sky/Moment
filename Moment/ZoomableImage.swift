import SwiftUI
import Combine
import AppKit

/// 滚轮缩放 + 拖动平移 + 双击复位的图片视图。
/// 外部用 `.id(url)` 切换图片时,状态会自动复位。
struct ZoomableImage: View {
    let image: NSImage
    private let padding = WaterfallLayout.viewerPadding
    private let maxScale: CGFloat = 10

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var pinchStart: CGFloat?
    @EnvironmentObject private var store: ImageStore

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(padding)
                .frame(width: geo.size.width, height: geo.size.height)
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
                                           scale: scale, in: geo.size)
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
                            let p = CGPoint(x: v.startLocation.x - geo.size.width / 2,
                                            y: v.startLocation.y - geo.size.height / 2)
                            zoom(to: start * v.magnification, at: p, in: geo.size)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .background(WheelCatcher { dy, precise, p in
                    zoom(to: scale * exp(dy * (precise ? 0.01 : 0.05)), at: p, in: geo.size)
                })
                .clipped()
                // 键盘 / 菜单缩放:以视图中心为锚点,0 表示复位
                .onReceive(store.zoomRequests) { factor in
                    withAnimation(.easeOut(duration: 0.15)) {
                        if factor == 0 { scale = 1; offset = .zero }
                        else { zoom(to: scale * factor, at: .zero, in: geo.size) }
                    }
                }
        }
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
    let onScroll: (CGFloat, Bool, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.onScroll = onScroll
        v.requiredModifiers = requiredModifiers
        v.ignoreMomentum = ignoreMomentum
    }
    static func dismantleNSView(_ v: CatcherView, coordinator: ()) { v.removeMonitor() }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, Bool, CGPoint) -> Void)?
        var requiredModifiers: NSEvent.ModifierFlags = []
        var ignoreMomentum = false
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
