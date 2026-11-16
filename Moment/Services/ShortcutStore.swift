import SwiftUI
import Combine
import UniformTypeIdentifiers

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
        case .toggleInfo: "x"
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
