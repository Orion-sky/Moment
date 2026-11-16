import SwiftUI
import Combine

/// 底部缩略图条,支持水平滚动条
struct ThumbnailStrip: View {
    @EnvironmentObject var store: ImageStore
    @State private var position = ScrollPosition()
    @State private var offsetX: CGFloat = 0
    @State private var viewWidth: CGFloat = 0
    @State private var wheel = WheelTarget()
    /// 出现后还欠一次"居中到当前照片"
    @State private var pendingCenter = true

    /// 连续滚轮时累计的目标位置(滚动位置的回报有延迟,连续几格要在上一格的目标上继续加)
    private final class WheelTarget {
        var x: CGFloat = 0
        var time: TimeInterval = 0
    }

    private var maxOffset: CGFloat { max(0, contentWidth - viewWidth) }

    /// 鼠标滚轮(纵向)转成横向滚动。
    /// 和点击、拖动滚动条走同一个滚动位置,这样滚完再点照片时不会从旧位置跳一下
    private func wheelScroll(dy: CGFloat, precise: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let base = now - wheel.time < 0.15 ? wheel.x : offsetX
        let x = min(max(base - (precise ? dy : dy * 12), 0), maxOffset)
        wheel.x = x
        wheel.time = now
        position.scrollTo(x: x)
    }

    /// 选中项变化后滚动缩略图条。
    /// 点击选中的:它本来就在眼前,只在被边缘挡住时挪到刚好露出,不重新居中(否则会跳一下)。
    /// 键盘翻页的:居中显示。
    private func reveal(_ index: Int, minimal: Bool, animated: Bool = true) {
        let left = 10 + CGFloat(index) * 92
        var x: CGFloat
        if !minimal {
            x = left + 42 - viewWidth / 2
        } else if left < offsetX {
            x = left - 10
        } else if left + 84 > offsetX + viewWidth {
            x = left + 84 + 10 - viewWidth
        } else {
            return
        }
        x = min(max(x, 0), maxOffset)
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { position.scrollTo(x: x) }
        } else {
            // 直接跳过去时先把要渲染的范围也挪过去,不用等滚动位置报回来
            offsetX = x
            position.scrollTo(x: x)
        }
    }

    /// 内容总宽度:每格 84、间距 8、两端各留 10。直接算出来,比懒加载列表的估算值准
    private var contentWidth: CGFloat {
        let n = CGFloat(store.images.count)
        return n * 84 + max(n - 1, 0) * 8 + 20
    }

    /// 当前要渲染的格子:屏幕内的,加上左右各多出几格。
    /// 系统的懒加载列表会把滚过的格子(连同它们的图片和图层)一直留着,滚得越多占得越多;
    /// 这里自己算范围,滚走的格子直接销毁,内存只和屏幕上有几格有关
    private var visibleRange: Range<Int> {
        let count = store.images.count
        guard count > 0 else { return 0..<0 }
        let width = viewWidth > 0 ? viewWidth : 1600   // 还没量到宽度时先按一屏估
        let first = Int(((offsetX - 10) / 92).rounded(.down)) - 4
        let last = Int(((offsetX + width - 10) / 92).rounded(.up)) + 4
        let lower = min(max(first, 0), count)
        return lower..<min(max(last, lower), count)
    }

    var body: some View {
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    ForEach(visibleRange, id: \.self) { index in
                        ThumbnailCell(url: store.images[index],
                                      picked: store.picked.contains(store.images[index]),
                                      selected: store.selected.contains(index),
                                      current: index == store.selection)
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                store.click(index, shift: flags.contains(.shift), command: flags.contains(.command))
                            }
                            .contextMenu { PhotoContextMenu(index: index) }
                            .offset(x: 10 + CGFloat(index) * 92, y: 8)
                    }
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // 系统滚动条(接了鼠标时是又粗又带底槽的那种)藏起来,换成下面自己画的细滚动条
            // 必须用 .never:.hidden 在接了鼠标时系统仍会把滚动条显示出来
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.x, $0.containerSize.width] } action: { _, v in
                offsetX = v[0]
                viewWidth = v[1]
                // 刚出现时还不知道宽度,没法居中;量到宽度后补上
                if pendingCenter, v[1] > 0 {
                    pendingCenter = false
                    reveal(store.selection, minimal: false, animated: false)
                }
            }
            .overlay(alignment: .bottom) {
                SlimScrollbar(offset: offsetX, contentLength: contentWidth, viewLength: viewWidth) { x in
                    position.scrollTo(x: x)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            .background(WheelCatcher(verticalOnly: true) { dy, precise, _ in
                wheelScroll(dy: dy, precise: precise)
            })
            // 从瀑布流切回来时,直接定位到当前照片(宽度量到之后执行,见上面)
            .onAppear { pendingCenter = true }
            // 切换筛选后列表整体换了,即使选中的序号没变也要重新定位
            .onChange(of: store.listVersion) {
                if viewWidth > 0 { reveal(store.selection, minimal: false, animated: false) } else { pendingCenter = true }
            }
            .onChange(of: store.selection) { _, new in
                reveal(new, minimal: store.selectionByClick)
            }
    }
}
