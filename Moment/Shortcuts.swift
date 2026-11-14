import SwiftUI
import Combine

/// 可以自定义按键的操作
enum ShortcutAction: String, CaseIterable, Identifiable {
    case previous, next, toggleMode, toggleInfo, toggleStrip, zoomIn, zoomOut, zoomReset
    var id: Self { self }

    var title: String {
        switch self {
        case .previous: "上一张"
        case .next: "下一张"
        case .toggleMode: "切换普通 / 瀑布流"
        case .toggleInfo: "开关信息栏"
        case .toggleStrip: "开关缩略图条"
        case .zoomIn: "放大"
        case .zoomOut: "缩小"
        case .zoomReset: "适应窗口"
        }
    }

    var defaultKey: String {
        switch self {
        case .previous: "a"
        case .next: "d"
        case .toggleMode: "v"
        case .toggleInfo: "w"
        case .toggleStrip: "s"
        case .zoomIn: "="
        case .zoomOut: "-"
        case .zoomReset: "0"
        }
    }

    /// 按住不放时是否连续触发(翻页、缩放可以;开关类不行,否则会来回闪)
    var repeats: Bool {
        switch self {
        case .previous, .next, .zoomIn, .zoomOut: true
        default: false
        }
    }
}

/// 快捷键设置:每个操作对应一个按键(单个字符,不分大小写),保存在偏好设置里
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private static let defaultsKey = "shortcuts"

    @Published private(set) var keys: [ShortcutAction: String] = [:]

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        for action in ShortcutAction.allCases {
            keys[action] = saved[action.rawValue] ?? action.defaultKey
        }
    }

    func key(for action: ShortcutAction) -> String { keys[action] ?? action.defaultKey }

    func action(for key: String) -> ShortcutAction? {
        ShortcutAction.allCases.first { keys[$0] == key }
    }

    /// 给操作指定按键。这个键已经被别的操作占用时,两者互换,保证不会有两个操作共用一个键
    func set(_ key: String, for action: ShortcutAction) {
        let old = self.key(for: action)
        if let other = self.action(for: key), other != action { keys[other] = old }
        keys[action] = key
        save()
    }

    func resetAll() {
        for action in ShortcutAction.allCases { keys[action] = action.defaultKey }
        save()
    }

    private func save() {
        let dict = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(dict, forKey: Self.defaultsKey)
    }

    /// 按键的显示名
    static func displayName(_ key: String) -> String {
        switch key {
        case " ": "空格"
        case "=": "= / +"
        default: key.uppercased()
        }
    }

    /// 把一次按键整理成可以保存的键;不能用作快捷键的返回 nil
    static func normalize(_ press: KeyPress) -> String? {
        // 带 ⌘ / Control / Option 的留给系统和菜单
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        var key = press.characters.lowercased()
        if key == "+" { key = "=" }   // 同一个键,按不按 Shift 都算
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return nil }
        // 回车、Tab、Esc、方向键、功能键有固定用途
        if scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value) { return nil }
        return key
    }
}

/// 设置窗口(⌘,)
struct SettingsView: View {
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
            } header: {
                Text("快捷键")
            } footer: {
                Text("点击右侧的按钮,再按下想用的键。可以用字母、数字、符号和空格;这个键已经被别的操作使用时,两者会互换。按 Esc 取消。")
                    .foregroundStyle(.secondary)
            }

            Section("固定的按键") {
                LabeledContent("上一张 / 下一张", value: "← / →")
                LabeledContent("瀑布流里打开选中的照片", value: "回车 或 双击")
                LabeledContent("退出全屏", value: "Esc")
                LabeledContent("瀑布流里调整每行张数", value: "⌘ + 滚轮")
                LabeledContent("多选", value: "Shift / ⌘ + 点击")
            }

            Section {
                Button("恢复默认快捷键") {
                    recording = nil
                    shortcuts.resetAll()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
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
    }
}
