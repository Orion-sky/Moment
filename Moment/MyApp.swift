import SwiftUI
import Combine
import AppKit

/// 外观:跟随系统 / 浅色 / 深色
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    /// 应用到整个应用(包括工具栏、菜单和窗口边框)
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

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

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ImageStore.shared
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 800, minHeight: 560)
                // 从访达打开文件由应用代理接收(见 AppDelegate)。
                // 已经有窗口时就用这个窗口接收,不要为每个文件另开一个
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") { store.chooseFolder() }
                    .keyboardShortcut("o")
            }
            // 应用里没有文字输入,编辑菜单的剪切 / 拷贝 / 粘贴换成拷贝照片
            CommandGroup(replacing: .pasteboard) {
                Button(store.selected.count > 1 ? "拷贝 \(store.selected.count) 张照片" : "拷贝照片") {
                    store.copyToPasteboard(store.selected)
                }
                .keyboardShortcut("c")
                .disabled(store.selected.isEmpty)
            }
            CommandGroup(before: .toolbar) {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Divider()
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

        // 设置窗口(菜单"设置…"或 ⌘,)
        Settings {
            SettingsView()
        }
    }
}
