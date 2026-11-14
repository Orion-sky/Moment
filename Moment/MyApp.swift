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
}

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ImageStore()
    @AppStorage("appearance") private var appearance = AppAppearance.system

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
