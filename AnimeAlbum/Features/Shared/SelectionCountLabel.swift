import SwiftUI

/// 「选择项目 / 已选择 N 张照片」计数标签：数字像里程表一样在裁切框里滚动
/// （变大向上滚、变小向下滚）并淡入淡出；占位文字与计数之间淡入淡出。
///
/// 不用系统 `.contentTransition(.numericText())`：它会给变化的字符加模糊，
/// 占位 ↔ 计数整行换字时整行发糊。
struct SelectionCountLabel: View {
    let count: Int
    let unit: String
    var placeholder = "选择项目"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 实际显示的数字：比 count 晚一帧更新，让滚动方向先生效（见 onChange）
    @State private var shownCount: Int
    @State private var rollsUp = true

    init(count: Int, unit: String, placeholder: String = "选择项目") {
        self.count = count
        self.unit = unit
        self.placeholder = placeholder
        _shownCount = State(initialValue: count)
    }

    var body: some View {
        ZStack {
            if shownCount == 0 {
                Text(placeholder)
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    Text("已选择 ")
                    rollingNumber
                    Text(" \(unit)")
                }
                .transition(.opacity)
            }
        }
        .monospacedDigit()
        .onChange(of: count) { old, new in
            rollsUp = new > old
            // 被移除的旧数字沿用它最后一次渲染时的 transition：方向必须先渲染一帧，
            // 下一轮再换数字，否则方向反转时旧数字会朝错误的方向滚走
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)) {
                    shownCount = new
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 0 ? placeholder : "已选择 \(count) \(unit)")
    }

    private var rollingNumber: some View {
        // 裁切框只框住数字本身：新旧数字在框内上下滑过，框外不可见
        ZStack {
            Text("\(shownCount)")
                .id(shownCount)
                .transition(numberTransition)
        }
        .clipped()
    }

    private var numberTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: rollsUp ? .bottom : .top).combined(with: .opacity),
            removal: .move(edge: rollsUp ? .top : .bottom).combined(with: .opacity))
    }
}
