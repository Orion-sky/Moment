import SwiftUI
import Combine
import UniformTypeIdentifiers

/// 通用:外观、主图缩放
struct GeneralSettings: View {
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

    /// 授权的文件夹最多直接列出几行,再多就滚动
    private static let visibleFolderRows = 4
    private static let folderRowHeight: CGFloat = 36

    private func folderRow(_ folder: URL) -> some View {
        // 不用 LabeledContent:它只有直接放在表单里才会左右分开,放进滚动区域后会整行挤在中间
        HStack {
            Text(folder.path).lineLimit(1).truncationMode(.middle).help(folder.path)
            Spacer(minLength: 12)
            Button("移除") { access.remove(folder) }
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
                if access.folders.count <= Self.visibleFolderRows {
                    ForEach(access.folders, id: \.self) { folderRow($0) }
                } else {
                    // 文件夹多了就在固定高度里滚动,不让设置窗口被撑得很长
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(access.folders, id: \.self) { folder in
                                folderRow(folder).frame(height: Self.folderRowHeight)
                                if folder != access.folders.last { Divider() }
                            }
                        }
                    }
                    .frame(height: Self.folderRowHeight * CGFloat(Self.visibleFolderRows))
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
