import SwiftUI
import Combine
import AppKit

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
