import SwiftUI
import Combine

/// 主图显示区
struct ViewerArea: View {
    @EnvironmentObject var store: ImageStore
    /// 右侧被信息栏盖住的宽度、底部被缩略图条盖住的高度
    var trailingInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// 顶部被工具栏盖住的高度
    var topInset: CGFloat = 0
    /// 放大时左下角有导航小图
    @State private var navigatorVisible = false

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = store.mainImage {
                ZoomableImage(image: image, trailingInset: trailingInset, bottomInset: bottomInset, topInset: topInset,
                              navigatorVisible: $navigatorVisible)
                    .id(store.current)
                    // 衔接动画进行时由飞行中的那张代替,结束后原位出现
                    .opacity(store.hero == nil ? 1 : 0)
                    .animation(nil, value: store.hero == nil)
            } else if !store.images.isEmpty {
                ProgressView()
            } else if !store.allImages.isEmpty {
                // 文件夹里有照片,但都被当前筛选条件排除了
                ContentUnavailableView {
                    Label("没有 \(store.filter.rawValue) 照片", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("这个文件夹里有 \(store.allImages.count) 张其他格式的照片")
                } actions: {
                    Button("显示全部") { store.filter = .all }
                }
            } else {
                ContentUnavailableView {
                    Label("没有图片", systemImage: "photo.on.rectangle")
                } description: {
                    Text("打开一个文件夹来浏览其中的照片")
                } actions: {
                    Button("打开文件夹…") { store.chooseFolder() }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // 筛选模式下,当前照片被标记时在角上显示(左下角留给放大时的导航小图)
            if store.culling, let url = store.current, store.picked.contains(url), store.hero == nil {
                Label("已标记", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.green.opacity(0.5)), in: .capsule)
                    .padding(14)
                    .padding(.top, topInset)
            }
        }
        .overlay(alignment: .leading) {
            // 左侧的翻页热区是从上到下一整条,会盖住左下角的导航小图、把它的拖动截走。
            // 小图显示时,热区让出下面这一段(小图最高 150,加上下留白)
            PageArrow(systemImage: "chevron.left", enabled: store.selection > 0) { store.move(-1) }
                .padding(.bottom, bottomInset + (navigatorVisible && store.mainImage != nil ? 178 : 0))
                .padding(.top, topInset)
        }
        .overlay(alignment: .trailing) {
            PageArrow(systemImage: "chevron.right", enabled: store.selection < store.images.count - 1) { store.move(1) }
                .padding(.trailing, trailingInset)
                .padding(.bottom, bottomInset)
                .padding(.top, topInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
