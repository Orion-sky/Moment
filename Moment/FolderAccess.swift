import SwiftUI
import Combine
import AppKit

/// 沙盒下的文件夹授权。
///
/// 沙盒里,双击一张照片时系统只允许应用读这一张,不允许读它所在的文件夹,
/// 所以没法翻看同一文件夹里的其他照片。办法是请用户授权一次文件夹,
/// 把授权存成"安全作用域书签";以后启动时恢复书签,就能直接读,不用再问。
/// 授权一个上级文件夹(比如整张存储卡、"图片"文件夹)会覆盖它里面所有的子文件夹。
@MainActor
final class FolderAccess: ObservableObject {
    static let shared = FolderAccess()
    private static let defaultsKey = "folderBookmarks"

    /// 已授权的文件夹(显示在设置里)
    @Published private(set) var folders: [URL] = []
    /// 路径 → 书签数据
    private var bookmarks: [String: Data] = [:]

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
        for (_, data) in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }   // 文件夹已不存在或卡没插:跳过
            // 书签过期(文件夹被移动过等)时重新生成一份
            let fresh = stale ? (try? url.bookmarkData(options: .withSecurityScope)) ?? data : data
            bookmarks[url.path] = fresh
            folders.append(url)
        }
        folders.sort { $0.path < $1.path }
        // 没能恢复的(比如存储卡没插)保留原样,不从存储里删掉:下次插上还能用
        var merged = saved
        for (path, data) in bookmarks { merged[path] = data }
        UserDefaults.standard.set(merged, forKey: Self.defaultsKey)
    }

    /// 现在能不能读这个文件夹(真的去试,而不是比对路径:有些位置不需要授权也能读)
    func canRead(_ folder: URL) -> Bool {
        guard let dir = opendir(folder.path) else { return false }
        closedir(dir)
        return true
    }

    /// 记住一个已经拿到权限的文件夹(用户刚在选择面板里选的,或者拖到程序坞图标上的)
    func remember(_ folder: URL) {
        let url = folder.standardizedFileURL
        // 已经被某个授权过的上级文件夹覆盖,就不用单独记
        if folders.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) { return }
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        _ = url.startAccessingSecurityScopedResource()
        bookmarks[url.path] = data
        folders.append(url)
        folders.sort { $0.path < $1.path }
        save(adding: url.path, data)
    }

    /// 请用户授权访问 folder(或它的上级)。返回授权后能不能读它
    func request(for folder: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.prompt = "授权"
        panel.message = "要浏览这个文件夹里的其他照片,需要你授权一次。\n"
            + "直接点「授权」即可;也可以选上一级文件夹(比如整张存储卡),这样里面的所有文件夹以后都不用再问。"
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        remember(chosen)
        return canRead(folder)
    }

    /// 在设置里手动添加(比如提前授权整个"图片"文件夹)
    func addByAsking() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "授权"
        panel.message = "选择允许 Moment 访问的文件夹。里面的所有子文件夹都会一并授权。"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(remember)
    }

    func remove(_ folder: URL) {
        folder.stopAccessingSecurityScopedResource()
        bookmarks[folder.path] = nil
        folders.removeAll { $0 == folder }
        var saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
        saved[folder.path] = nil
        UserDefaults.standard.set(saved, forKey: Self.defaultsKey)
    }

    private func save(adding path: String, _ data: Data) {
        var saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
        saved[path] = data
        UserDefaults.standard.set(saved, forKey: Self.defaultsKey)
    }
}
