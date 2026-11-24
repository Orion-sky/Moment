import SwiftUI
import Combine
import UniformTypeIdentifiers

/// 固定按键:不能自定义的,只读
struct FixedKeysSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("上一张 / 下一张", value: "← / →")
                LabeledContent("瀑布流里上下左右移动", value: "W A S D 或 方向键")
                LabeledContent("瀑布流里打开选中的照片", value: "回车 或 双击")
                LabeledContent("依次:退出筛选模式 → 清除标记 → 退出全屏", value: "Esc")
                LabeledContent("瀑布流里调整每行张数", value: "⌘ + 滚轮")
                LabeledContent("多选", value: "Shift / ⌘ + 点击")
            } header: {
                Text("鼠标和键盘")
            }

            Section("菜单快捷键") {
                LabeledContent("打开文件夹", value: "⌘O")
                LabeledContent("拷贝选中的照片", value: "⌘C")
                LabeledContent("普通模式 / 瀑布流模式", value: "⌘1 / ⌘2")
                LabeledContent("放大 / 缩小 / 适应窗口", value: "⌘+ / ⌘- / ⌘0")
                LabeledContent("开关缩略图条 / 信息栏", value: "⌥⌘T / ⌥⌘I")
                LabeledContent("设置", value: "⌘,")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
