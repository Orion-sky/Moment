import SwiftUI
import Combine

/// 可以自定义按键的操作
enum ShortcutAction: String, CaseIterable, Identifiable {
    case previous, next, toggleMode, toggleInfo, toggleStrip, zoomIn, zoomOut, zoomReset
    case toggleCulling, togglePick, toggleFullScreen
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
        case .toggleCulling: "开关筛选模式"
        case .togglePick: "标记 / 取消标记照片(自动进入筛选模式)"
        case .toggleFullScreen: "进入 / 退出全屏"
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
        case .toggleCulling: "c"
        case .togglePick: " "
        case .toggleFullScreen: "f"
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

/// 通用:外观、主图缩放
private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @AppStorage("wheelZoomSpeed") private var wheelZoomSpeed = 1.0

    var body: some View {
        Form {
            Section("外观") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { appearance.apply() }
            }

            Section {
                LabeledContent("滚轮缩放速度") {
                    HStack(spacing: 8) {
                        Text("慢").foregroundStyle(.secondary)
                        Slider(value: $wheelZoomSpeed, in: 0.25...3, step: 0.25)
                            .frame(width: 170)
                        Text("快").foregroundStyle(.secondary)
                        Text(String(format: "%.2g×", wheelZoomSpeed))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                if wheelZoomSpeed != 1 {
                    Button("恢复默认速度") { wheelZoomSpeed = 1 }
                }
            } header: {
                Text("主图缩放")
            } footer: {
                Text("用鼠标滚轮缩放主图的快慢。轻轻一拨就变化太大时调慢;要滚很久才放大时调快。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 快捷键:可以自定义的单键操作
private struct ShortcutSettings: View {
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
                Text("点击右侧的按钮,再按下想用的键。可以用字母、数字、符号和空格;这个键已经被别的操作使用时,两者会互换。按 Esc 取消。")
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

/// 固定按键:不能自定义的,只读
private struct FixedKeysSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("上一张 / 下一张", value: "← / →")
                LabeledContent("瀑布流里打开选中的照片", value: "回车 或 双击")
                LabeledContent("退出筛选模式;不在筛选模式时退出全屏", value: "Esc")
                LabeledContent("瀑布流里调整每行张数", value: "⌘ + 滚轮")
                LabeledContent("多选", value: "Shift / ⌘ + 点击")
            } header: {
                Text("鼠标和键盘")
            }

            Section("菜单快捷键") {
                LabeledContent("打开文件夹", value: "⌘O")
                LabeledContent("普通模式 / 瀑布流模式", value: "⌘1 / ⌘2")
                LabeledContent("放大 / 缩小 / 适应窗口", value: "⌘+ / ⌘- / ⌘0")
                LabeledContent("开关缩略图条 / 信息栏", value: "⌥⌘T / ⌥⌘I")
                LabeledContent("设置", value: "⌘,")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
