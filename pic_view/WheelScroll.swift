import SwiftUI
import AppKit

/// 让鼠标滚轮(纵向滚动量)在所覆盖区域内驱动横向 ScrollView。
/// 用法:`.background(WheelToHorizontalScroll())` 加在 ScrollView 上。
struct WheelToHorizontalScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ nsView: MonitorView, context: Context) {}
    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) { nsView.removeMonitor() }

    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return event }
            // 已经有横向分量(触控板横滑)时交给系统处理
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
            guard let root = window?.contentView,
                  let sv = Self.horizontalScrollView(in: root, at: event.locationInWindow) else { return event }
            let clip = sv.contentView
            guard let doc = sv.documentView else { return event }
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            let maxX = max(0, doc.frame.width - clip.bounds.width)
            let x = min(max(clip.bounds.origin.x - dy, 0), maxX)
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            sv.reflectScrolledClipView(clip)
            return nil
        }

        private static func horizontalScrollView(in view: NSView, at windowPoint: NSPoint) -> NSScrollView? {
            if let sv = view as? NSScrollView,
               sv.bounds.contains(sv.convert(windowPoint, from: nil)),
               let doc = sv.documentView, doc.frame.width > sv.contentView.bounds.width {
                return sv
            }
            for sub in view.subviews {
                if let found = horizontalScrollView(in: sub, at: windowPoint) { return found }
            }
            return nil
        }
    }
}
