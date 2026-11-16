import SwiftUI
import Combine

/// 模式切换时飞行的那张照片:从起点位置缩放移动到终点位置。
/// 外观在两端都和真实的视图完全一致(没有阴影、圆角随位置过渡、没有回弹),
/// 这样飞到位后换成真实视图时看不出切换。
struct HeroOverlay: View {
    @EnvironmentObject var store: ImageStore
    let flight: HeroFlight
    let onDone: () -> Void
    @State private var arrived = false

    var body: some View {
        let r = arrived ? flight.to : flight.from
        // 格子有 4 的圆角,主图没有
        let inCell = arrived == flight.endsInCell
        // 飞行途中大图解码好了就直接换上,不用等到位后再跳一下
        Image(nsImage: store.mainImage ?? flight.image)
            .resizable()
            .scaledToFill()
            .frame(width: r.width, height: r.height)
            .clipShape(RoundedRectangle(cornerRadius: inCell ? 4 : 0))
            .offset(x: r.minX, y: r.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.3)) { arrived = true } completion: { onDone() }
            }
    }
}
