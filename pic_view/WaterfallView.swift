import SwiftUI
import AppKit

/// 瀑布流模式:所有照片按原始比例分列铺开,纵向滚动。
/// 单击选择(Shift / ⌘ 多选),双击或回车回到普通模式查看该照片。
///
/// 每张图的位置由宽高比直接算出,只渲染屏幕附近的格子,
/// 所以无论有多少照片、滚到多远,进入和定位都是直接跳转。
struct WaterfallView: View {
    @EnvironmentObject var store: ImageStore
    @Environment(\.displayScale) private var displayScale
    private let spacing = WaterfallLayout.spacing
    /// 每行显示几张(工具栏上的滑块调节)
    @AppStorage("waterfallColumns") private var columnCount = 5
    /// 可见范围按这个步长更新,避免每滚动一个像素都刷新
    private let step: CGFloat = 200
    /// 屏幕上下额外渲染的距离
    private let overscan: CGFloat = 600

    private let columnAnimation = Animation.easeOut(duration: 0.25)
    @State private var zoomScale: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var zoomOffset: CGSize = .zero
    @State private var position = ScrollPosition()
    @State private var bucket = 0
    @State private var scroll = ScrollOffsetBox()

    var body: some View {
        GeometryReader { geo in
            if store.aspects.count == store.images.count {
                let layout = makeLayout(store.aspects, width: geo.size.width)
                let _ = (scroll.frames = layout.frames)
                // 排版由这三项决定:宽度(开关信息栏、缩放窗口)、已读到的尺寸、每行张数
                let layoutKey = LayoutKey(width: geo.size.width, loaded: store.aspectsLoaded, columns: columnCount)
                let viewHeight = geo.size.height
                // 第一次渲染时还没滚动到位:直接按选中照片所在的位置算可见范围,
                // 这样最先创建、最先开始加载的就是选中照片周围的格子,而不是最顶上的
                let activeBucket = scroll.started ? bucket : Int(centeredOffset(layout, viewHeight: geo.size.height) / step)
                let _ = reportSelectionRect(layout.frames, offset: scroll.started ? scroll.y : centeredOffset(layout, viewHeight: geo.size.height))
                let top = CGFloat(activeBucket) * step - overscan
                let bottom = CGFloat(activeBucket) * step + step + geo.size.height + overscan
                let visible = layout.frames.indices.filter {
                    layout.frames[$0].maxY >= top && layout.frames[$0].minY <= bottom
                }
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        ForEach(visible, id: \.self) { index in
                            let f = layout.frames[index]
                            cell(index, frame: f, priority: loadPriority(index, in: layout.frames))
                                .frame(width: f.width, height: f.height)
                                .offset(x: f.minX, y: f.minY)
                        }
                    }
                    .frame(width: geo.size.width, height: layout.height, alignment: .topLeading)
                }
                .scrollPosition($position)
                // 调整每行张数时的整体缩放(见下面 onChange 里的说明)
                .scaleEffect(zoomScale, anchor: zoomAnchor)
                .offset(zoomOffset)
                // 按住 Command 滚动滚轮:调整每行张数(向上滚 = 放大 = 张数变少)
                .background(WheelCatcher(requiredModifiers: .command, ignoreMomentum: true) { dy, precise, _ in
                    adjustColumns(dy: dy, precise: precise)
                })
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                    scroll.y = y
                    reportSelectionRect(layout.frames, offset: y)
                    // 排版刚变、还没重新对齐时不更新锚点,否则会记成错的照片
                    if scroll.settledKey == layoutKey { scroll.updateAnchor(prefer: store.selection, viewHeight: viewHeight) }
                    let b = Int(y / step)
                    if b != bucket { bucket = b }
                }
                // 排版变化(信息栏开关、窗口缩放、调整每行张数、读到新一批尺寸)后,
                // 让锚点照片留在屏幕上的同一高度。锚点优先是选中的那张(它在屏幕内时)
                .onChange(of: layoutKey) { old, new in
                    let columnsChanged = old.columns != new.columns
                    // 锚点照片在旧排版下的屏幕位置和宽度(下面 defer 里会被更新成新的)
                    let oldMidX = scroll.anchorMidX, oldWidth = scroll.anchorWidth
                    let oldMidY = scroll.anchorScreen * viewHeight
                    defer {
                        scroll.settledKey = layoutKey
                        scroll.updateAnchor(prefer: store.selection, viewHeight: viewHeight)
                    }
                    guard let i = scroll.anchor, layout.frames.indices.contains(i) else { return }
                    let f = layout.frames[i]
                    let y = min(max(f.midY - oldMidY, 0), max(0, layout.height - viewHeight))
                    if abs(y - scroll.y) > 0.5 {
                        scroll.y = y
                        bucket = Int(y / step)
                        position.scrollTo(y: y)
                    }
                    guard columnsChanged, oldWidth > 0, f.width > 0 else { return }

                    // 调整每行张数的动画:不让每张照片各自飞到新位置(满屏乱动,看着眼花),
                    // 而是立即换成新排版,再把整个画面当成一个整体做一次缩放——
                    // 起始时缩放到"锚点照片和调整前一样大、在同一位置",然后平滑回到正常大小。
                    // 这样画面里只有一个统一的放大 / 缩小动作,锚点照片始终连续。
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        zoomAnchor = UnitPoint(x: f.midX / max(geo.size.width, 1),
                                               y: (f.midY - y) / max(viewHeight, 1))
                        zoomScale = oldWidth / f.width
                        zoomOffset = CGSize(width: oldMidX - f.midX, height: oldMidY - (f.midY - y))
                    }
                    DispatchQueue.main.async {
                        withAnimation(columnAnimation) {
                            zoomScale = 1
                            zoomOffset = .zero
                        }
                    }
                }
                .onAppear { scroll.settledKey = layoutKey }
                .overlay(alignment: .bottom) {
                    if store.aspectsLoaded < store.images.count {
                        Text("正在读取照片尺寸 \(store.aspectsLoaded) / \(store.images.count)")
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                    }
                }
                .onAppear {
                    reveal(layout, viewHeight: geo.size.height, center: true)
                    scroll.started = true
                }
                // 切换筛选后列表整体换了,重新定位到当前照片
                .onChange(of: store.listVersion) { reveal(layout, viewHeight: geo.size.height, center: true) }
                .onChange(of: store.selection) { reveal(layout, viewHeight: geo.size.height, center: false) }
            }
        }
        .clipped()
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// 加载优先级:离选中照片越近越高,选中的那张最高
    private func loadPriority(_ index: Int, in frames: [CGRect]) -> Double {
        guard frames.indices.contains(store.selection) else { return 0 }
        let a = frames[index], b = frames[store.selection]
        return -Double(hypot(a.midX - b.midX, a.midY - b.midY))
    }

    private func cell(_ index: Int, frame: CGRect, priority: Double) -> some View {
        WaterfallCell(url: store.images[index],
                      // 按格子的实际像素大小(高分屏要乘以倍率)取图;竖拍照片的长边是高度
                      pixelSize: ThumbnailCache.waterfallSize(forPixels: max(frame.width, frame.height) * displayScale),
                      priority: priority,
                      // 选中的这张:清晰缩略图还没读出来时先用主图顶着,
                      // 否则衔接动画飞到位后会露出一下灰色占位
                      fallback: index == store.selection ? store.mainImage : nil,
                      selected: store.selected.contains(index),
                      current: index == store.selection)
            // 衔接动画进行时,选中的格子由飞行中的那张代替
            .opacity(index == store.selection && store.hero != nil ? 0 : 1)
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                store.click(index, shift: flags.contains(.shift), command: flags.contains(.command))
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                store.click(index, shift: false, command: false)
                // 选中项刚换成这张,先更新它的位置,衔接动画才会从这张起飞
                reportSelectionRect(scroll.frames, offset: scroll.y)
                store.mode = .single
            })
            .contextMenu { PhotoContextMenu(index: index) }
    }

    /// 不同鼠标的滚轮差别很大:普通滚轮一格发一个事件;
    /// MX Master 这类滚轮轻轻一拨就连发很多个事件(开了平滑滚动时还是连续的小数值)。
    /// 所以不能"一个事件调一列",而是按"一次拨动调一列"来算。
    private func adjustColumns(dy: CGFloat, precise: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        // 停顿超过 0.25 秒算一次新的拨动,之前攒的量作废
        if now - scroll.columnLastEvent > 0.25 { scroll.columnWheel = 0 }
        scroll.columnLastEvent = now
        // 刚调过一列:接下来 0.22 秒内同一次拨动的后续事件全部丢掉
        guard now - scroll.columnLastStep > 0.22 else { scroll.columnWheel = 0; return }

        // 连续数值要攒到一定量才算数;逐格的滚轮一格就算数
        scroll.columnWheel += precise ? dy : (dy > 0 ? 40 : -40)
        guard abs(scroll.columnWheel) >= 40 else { return }

        let change = scroll.columnWheel > 0 ? -1 : 1
        scroll.columnWheel = 0
        scroll.columnLastStep = now
        let next = min(max(columnCount + change, 2), 12)
        if next != columnCount { columnCount = next }
    }

    private func makeLayout(_ aspects: [CGFloat], width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        WaterfallLayout.make(aspects, width: width, columns: columnCount)
    }

    /// 把选中照片此刻在屏幕上的位置告诉 store,切回普通模式时衔接动画从这里起飞
    private func reportSelectionRect(_ frames: [CGRect], offset: CGFloat) {
        store.waterfallSelectionRect = frames.indices.contains(store.selection)
            ? frames[store.selection].offsetBy(dx: 0, dy: -offset) : nil
    }

    /// 让选中的照片居中时的滚动位置
    private func centeredOffset(_ layout: (frames: [CGRect], height: CGFloat), viewHeight: CGFloat) -> CGFloat {
        WaterfallLayout.centeredOffset(layout, index: store.selection, viewHeight: viewHeight)
    }

    /// 让当前选中的照片可见。center: 居中(进入时);否则只在它不在屏幕内时做最小滚动
    private func reveal(_ layout: (frames: [CGRect], height: CGFloat), viewHeight: CGFloat, center: Bool) {
        guard layout.frames.indices.contains(store.selection) else { return }
        let f = layout.frames[store.selection]
        var y: CGFloat
        if center {
            y = f.midY - viewHeight / 2
        } else if f.minY < scroll.y {
            y = f.minY - spacing
        } else if f.maxY > scroll.y + viewHeight {
            y = f.maxY - viewHeight + spacing
        } else {
            // 已经在屏幕内:不滚动,但把锚点换成新选中的这张
            scroll.updateAnchor(prefer: store.selection, viewHeight: viewHeight)
            return
        }
        y = min(max(y, 0), max(0, layout.height - viewHeight))
        scroll.y = y
        scroll.updateAnchor(prefer: store.selection, viewHeight: viewHeight)
        bucket = Int(y / step)
        position.scrollTo(y: y)
    }
}

/// 记录当前滚动位置,不触发界面刷新
private final class ScrollOffsetBox {
    var y: CGFloat = 0
    /// Command + 滚轮调列数时累计的滚动量
    var columnWheel: CGFloat = 0
    /// 锚点照片在屏幕上的水平中心和宽度(调整列数的缩放动画要用)
    var anchorMidX: CGFloat = 0
    var anchorWidth: CGFloat = 0
    var columnLastEvent: TimeInterval = 0
    var columnLastStep: TimeInterval = 0
    /// 是否已经完成进入时的初次定位
    var started = false
    /// 最近一次排版的结果
    var frames: [CGRect] = []
    /// 锚点照片:选中的那张在屏幕内时就是它,否则是屏幕顶部的那张
    var anchor: Int?
    /// 锚点照片的中心在屏幕高度上的位置(0 = 顶边,1 = 底边)
    var anchorScreen: CGFloat = 0
    /// 锚点对应的排版;排版变了但还没重新对齐时,不更新锚点
    var settledKey: LayoutKey?

    func updateAnchor(prefer selection: Int, viewHeight: CGFloat) {
        if frames.indices.contains(selection),
           frames[selection].maxY > y, frames[selection].minY < y + viewHeight {
            anchor = selection
        } else {
            anchor = frames.firstIndex { $0.maxY > y }
        }
        anchorScreen = anchor.map { (frames[$0].midY - y) / max(viewHeight, 1) } ?? 0
        anchorMidX = anchor.map { frames[$0].midX } ?? 0
        anchorWidth = anchor.map { frames[$0].width } ?? 0
    }
}

private struct LayoutKey: Hashable {
    let width: CGFloat
    let loaded: Int
    let columns: Int
}

struct WaterfallCell: View {
    let url: URL
    /// 需要的图片尺寸(最长边像素),见 ThumbnailCache.waterfallSizes
    let pixelSize: Int
    let priority: Double
    let fallback: NSImage?
    let selected: Bool
    let current: Bool
    @State private var image: NSImage?
    /// `image` 目前显示的是哪个文件
    @State private var shownURL: URL?

    private struct LoadKey: Hashable {
        let url: URL
        let size: Int
    }

    var body: some View {
        Color.secondary.opacity(0.15)
            .overlay {
                if let image = image ?? fallback {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(selected && !current ? 0.25 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(current ? 1 : 0.6), lineWidth: current ? 3 : (selected ? 2 : 0)))
            .contentShape(Rectangle())
            .task(id: LoadKey(url: url, size: pixelSize)) {
                let cache = ThumbnailCache.shared
                if let exact = cache.cached(url, size: pixelSize) {
                    image = exact
                } else {
                    // 先用手头最清晰的图占位。同一张照片只是换了尺寸(调了列数)时,保留正在显示的图;
                    // 有主图顶着时不用模糊的小图,避免"清晰 → 模糊 → 清晰"地跳
                    if let other = cache.bestCached(url), fallback == nil || other.size.width > 200 {
                        image = other
                    } else if shownURL != url {
                        image = nil
                    }
                    shownURL = url
                    if let full = await cache.load(url, size: pixelSize, priority: priority) { image = full }
                }
                shownURL = url
            }
    }
}
