import SwiftUI
import Combine
import UniformTypeIdentifiers

/// 快捷键:可以自定义的单键操作
struct ShortcutSettings: View {
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// 正在等待按键的那一项
    @State private var recording: ShortcutAction?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        Button {
                            recording = recording == action ? nil : action
                            focused = true
                        } label: {
                            Text(recording == action ? "请按一个键…" : ShortcutStore.displayName(shortcuts.key(for: action)))
                                .monospaced()
                                .frame(minWidth: 96)
                        }
                        .buttonStyle(.bordered)
                        .tint(recording == action ? .accentColor : nil)
                    }
                }
            } footer: {
                Text("瀑布流里 W A S D 固定用来上下左右移动,这四个键上的操作只在普通模式下起作用。点击右侧的按钮,再按下想用的键。可以用字母、数字、符号和空格;这个键已经被别的操作使用时,两者会互换。按 Esc 取消。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("恢复默认快捷键") {
                    recording = nil
                    shortcuts.resetAll()
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard let action = recording else { return .ignored }
            if press.key == .escape { recording = nil; return .handled }
            guard let key = ShortcutStore.normalize(press) else { return .handled }
            shortcuts.set(key, for: action)
            recording = nil
            return .handled
        }
        // 切到别的分栏时,不再等待按键
        .onDisappear { recording = nil }
    }
}
