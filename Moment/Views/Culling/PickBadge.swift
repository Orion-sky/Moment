import SwiftUI
import Combine

/// 被标记照片右上角的绿色对勾
struct PickBadge: View {
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}
