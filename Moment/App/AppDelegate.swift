import SwiftUI
import Combine
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 关闭窗口即退出应用
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 访达把文件交给应用:双击照片、"打开方式"、拖到程序坞图标上。在已有的窗口里打开
    func application(_ application: NSApplication, open urls: [URL]) {
        // 放到下一轮再处理:第一次打开某个文件夹里的照片时可能要弹授权面板,
        // 不能在系统还在派发"打开文件"事件的过程中弹
        DispatchQueue.main.async { ImageStore.shared.open(urls: urls) }
        // 极少数情况下这时还没有窗口:请 SwiftUI 建一个(和点程序坞图标时走的是同一条路)
        if !NSApp.windows.contains(where: { $0.canBecomeMain }) {
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
        // 把应用切到前台、窗口提到最前。不做这一步的话,照片其实已经打开了,
        // 但窗口留在别的应用后面,看起来像没反应,要手动点一下才出现
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }


}
