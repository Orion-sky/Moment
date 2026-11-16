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
    @ObservedObject private var access = FolderAccess.shared
    @State private var defaultAppStatus: String?
    @State private var settingDefault = false

    /// 应用是否放在"应用程序"文件夹里。放在别处(比如 Xcode 的构建目录)也能设为默认,
    /// 但那个位置的应用被删除或重新生成后,默认打开方式会失效
    private var installedInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// 把常见的图片格式和各家相机的 RAW 格式的默认打开方式都设成本应用
    private func makeDefaultViewer() {
        settingDefault = true
        defaultAppStatus = nil
        let extensions = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
            + ImageMeta.rawExts.sorted()
        // 系统是按"类型"而不是扩展名记默认应用的;系统不认识的扩展名(dyn. 开头)跳过
        var types: [UTType] = []
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !type.identifier.hasPrefix("dyn."), !types.contains(type) {
                types.append(type)
            }
        }
        let app = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        func isDefault(_ type: UTType) -> Bool {
            NSWorkspace.shared.urlForApplication(toOpen: type)?.standardizedFileURL == app.standardizedFileURL
        }
        Task {
            var already = 0, changed = 0
            var failed: [String] = []
            for type in types {
                // 已经是默认的跳过:再点一次不会把确认框重新弹一遍
                if isDefault(type) { already += 1; continue }
                // 先试系统的旧接口:它不经过确认框。成功就不用再问
                if LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .all, bundleID as CFString) == noErr,
                   isDefault(type) {
                    changed += 1
                    continue
                }
                // 旧接口不行再用新接口,这条路系统会逐个弹确认
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                    changed += 1
                } catch {
                    failed.append(type.preferredFilenameExtension ?? type.identifier)
                }
            }
            settingDefault = false
            var parts: [String] = []
            if changed > 0 { parts.append("新设置了 \(changed) 种格式") }
            if already > 0 { parts.append("\(already) 种原本就是默认") }
            if !failed.isEmpty { parts.append("这些没有成功:\(failed.joined(separator: "、"))") }
            defaultAppStatus = parts.joined(separator: ";") + "。"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("默认看图应用") {
                    Button(settingDefault ? "正在设置…" : "设为默认") { makeDefaultViewer() }
                        .disabled(settingDefault)
                }
                if let defaultAppStatus {
                    Text(defaultAppStatus).foregroundStyle(.secondary)
                }
            } footer: {
                Text(installedInApplications
                     ? "把 JPG、PNG、HEIC、TIFF 等常见图片和相机 RAW 文件的默认打开方式设为 Moment。系统可能会弹出确认。"
                     : "Moment 目前不在「应用程序」文件夹里。现在也可以设为默认,但这个位置的应用被删除或重新生成后会失效,建议先把它移到「应用程序」文件夹。")
                    .foregroundStyle(.secondary)
            }

            Section {
                if access.folders.isEmpty {
                    Text("还没有授权任何文件夹").foregroundStyle(.secondary)
                }
                ForEach(access.folders, id: \.self) { folder in
                    LabeledContent {
                        Button("移除") { access.remove(folder) }
                    } label: {
                        Text(folder.path).lineLimit(1).truncationMode(.middle).help(folder.path)
                    }
                }
                Button("添加文件夹…") { access.addByAsking() }
            } header: {
                Text("可以访问的文件夹")
            } footer: {
                Text("双击照片打开时,Moment 需要所在文件夹的权限才能翻看其他照片。授权过的文件夹(包括里面的子文件夹)会记在这里,不用再问。可以提前把整张存储卡或「图片」文件夹加进来。")
                    .foregroundStyle(.secondary)
            }

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
                LabeledContent("拷贝选中的照片", value: "⌘C")
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
