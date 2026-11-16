import SwiftUI
import Combine
import UniformTypeIdentifiers

/// 设置窗口(⌘,):顶部分栏
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { GeneralSettings() }
            Tab("快捷键", systemImage: "keyboard") { ShortcutSettings() }
            Tab("固定按键", systemImage: "list.bullet.rectangle") { FixedKeysSettings() }
        }
        .frame(width: 480)
    }
}
