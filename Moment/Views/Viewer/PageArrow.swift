import SwiftUI
import Combine

/// 主图两侧的翻页热区:鼠标移入才显示箭头
struct PageArrow: View {
    let systemImage: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                // 液态玻璃按钮:会折射后面的照片,按下时有反馈
                .glassEffect(.regular.interactive(), in: .circle)
                .opacity(hovering && enabled ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: hovering)
        }
        .frame(width: 80)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if enabled { action() } }
        .allowsHitTesting(enabled)
    }
}
