import SwiftUI
import Combine

/// 操作条上的文字按钮:可点时是清楚的前景色,鼠标移上去有底色,不可点时才变淡。
/// (系统的无边框按钮默认是灰色文字,看起来像不能点)
struct BarButtonStyle: ButtonStyle {
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration, color: color) }

    private struct Content: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .fontWeight(.medium)
                .foregroundStyle(color.opacity(isEnabled ? 1 : 0.35))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.22 : hovering ? 0.12 : 0),
                            in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}
