import SwiftUI
import AppKit

/// 全屏时让工具栏自动隐藏(鼠标移到屏幕顶部才滑出来),照片可以铺满整个屏幕。
///
/// 窗口模式下工具栏和内容在同一个窗口里,内容可以铺到工具栏后面;
/// 但全屏时系统把工具栏放进另一个单独的层,带着自己的底色,应用没法让它变透明。
/// 系统只提供了"全屏时自动隐藏工具栏"这一个选项,而且只能由窗口的 delegate 来回答。
/// SwiftUI 的窗口已经有自己的 delegate,所以这里套一层:这一个问题由我们回答,其余的原样转交。
///
/// 用法:`.background(FullScreenToolbarAutoHide())`
struct FullScreenToolbarAutoHide: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { InstallerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.delegate is DelegateProxy) else { return }
            let proxy = DelegateProxy(original: window.delegate)
            // window.delegate 是弱引用,把代理挂在窗口上保证它活着
            objc_setAssociatedObject(window, &DelegateProxy.key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            window.delegate = proxy
        }
    }

    private final class DelegateProxy: NSObject, NSWindowDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0
        private weak var original: NSWindowDelegate?

        init(original: NSWindowDelegate?) { self.original = original }

        func window(_ window: NSWindow,
                    willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
        ) -> NSApplication.PresentationOptions {
            [.fullScreen, .autoHideToolbar, .autoHideMenuBar]
        }

        // 其余所有 delegate 方法原样转交给 SwiftUI 原来的 delegate
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original, original.responds(to: aSelector) { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
