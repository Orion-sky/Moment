import SwiftUI
import Combine

/// 右侧参数面板
struct InfoPanel: View {
    @EnvironmentObject var store: ImageStore
    @State private var position = ScrollPosition()
    /// [滚动位置, 内容高度, 可见高度]
    @State private var metrics: [CGFloat] = [0, 0, 0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.current != nil {
                    ForEach(store.meta) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.headline)
                            ForEach(section.rows) { row in
                                HStack(alignment: .top) {
                                    Text(row.name).foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)
                                    Text(row.value).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .font(.callout)
                            }
                        }
                    }
                } else {
                    Text("无参数").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 和缩略图条一样:藏起系统滚动条,换成细滚动条(内容一屏放得下时不显示)
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: [CGFloat].self) {
            [$0.contentOffset.y, $0.contentSize.height, $0.containerSize.height]
        } action: { _, new in
            metrics = new
        }
        .overlay(alignment: .trailing) {
            SlimScrollbar(axis: .vertical, offset: metrics[0], contentLength: metrics[1], viewLength: metrics[2]) { y in
                position.scrollTo(y: y)
            }
            .padding(.vertical, 12)
            .padding(.trailing, 3)
        }
    }
}
