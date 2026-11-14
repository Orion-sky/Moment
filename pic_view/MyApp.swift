import SwiftUI
import Combine
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 关闭窗口即退出应用
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ImageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 800, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") { store.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(before: .toolbar) {
                Button("普通模式") { store.mode = .single }
                    .keyboardShortcut("1")
                Button("瀑布流模式") { store.mode = .waterfall }
                    .keyboardShortcut("2")
                Divider()
                Button("放大") { store.zoomRequests.send(1.25) }
                    .keyboardShortcut("+")
                Button("缩小") { store.zoomRequests.send(0.8) }
                    .keyboardShortcut("-")
                Button("适应窗口") { store.zoomRequests.send(0) }
                    .keyboardShortcut("0")
                Divider()
            }
        }
    }
}
