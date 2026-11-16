import SwiftUI
import Combine

/// 细的圆头滚动条:平时很淡,鼠标移上去或拖动时变粗变深;可以拖动
struct SlimScrollbar: View {
    var axis: Axis = .horizontal
    let offset: CGFloat
    let contentLength: CGFloat
    let viewLength: CGFloat
    let scrollTo: (CGFloat) -> Void

    @State private var hovering = false
    @State private var dragStart: CGFloat?

    /// 可抓取区域的厚度(看到的细条比它细)
    private let grip: CGFloat = 10

    var body: some View {
        let horizontal = axis == .horizontal
        GeometryReader { geo in
            let track = horizontal ? geo.size.width : geo.size.height
            let scrollable = contentLength - viewLength
            if scrollable > 1, track > 0, viewLength > 0 {
                let thumb = min(max(36, track * viewLength / contentLength), track)
                let travel = max(track - thumb, 1)
                let pos = min(max(offset / scrollable, 0), 1) * travel
                let active = hovering || dragStart != nil
                let thickness: CGFloat = active ? 7 : 5
                // 透明的抓取区域里贴边放一根细条
                ZStack(alignment: horizontal ? .bottom : .trailing) {
                    Color.clear
                    Capsule()
                        .fill(.primary.opacity(active ? 0.75 : 0.5))
                        .frame(width: horizontal ? thumb : thickness, height: horizontal ? thickness : thumb)
                        .animation(.easeOut(duration: 0.12), value: active)
                }
                .frame(width: horizontal ? thumb : grip, height: horizontal ? grip : thumb)
                .contentShape(Rectangle())
                .gesture(
                    // 用全局坐标:滑块自己在动,用它自身的坐标量出来的拖动距离会不准
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in
                            let start = dragStart ?? offset
                            dragStart = start
                            let moved = horizontal ? v.translation.width : v.translation.height
                            scrollTo(min(max(start + moved / travel * scrollable, 0), scrollable))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .offset(x: horizontal ? pos : 0, y: horizontal ? 0 : pos)
            }
        }
        .frame(width: horizontal ? nil : grip, height: horizontal ? grip : nil)
        .onHover { hovering = $0 }
    }
}
