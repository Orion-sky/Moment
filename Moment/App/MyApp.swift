import SwiftUI
import Combine
import AppKit

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
