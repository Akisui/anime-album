import SwiftUI

/// iOS 26 的 Liquid Glass：系统导航栏 / Tab 栏 / 菜单用 iOS 26 SDK 编译后自动是玻璃；
/// 自绘的浮层（查看器按钮、视频控制条、选择栏、主按钮）在这里统一处理，iOS 18 保持原样
extension View {
    /// 玻璃底（iOS 26）或材质底（iOS 18）
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, interactive: Bool = false,
                                    fallback: Material = .regularMaterial) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    /// 主按钮：iOS 26 玻璃强调样式，iOS 18 实心强调样式
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// 查看器顶栏的圆按钮：iOS 26 玻璃圆（44pt），iOS 18 不加底
    @ViewBuilder
    func viewerCircleButton() -> some View {
        if #available(iOS 26.0, *) {
            frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
        }
    }
}

enum GlassSymbols {
    /// 「…」：iOS 26 的导航栏按钮自带玻璃圆底，用不带圈的符号（带圈的会成圈中圈）
    static var more: String {
        if #available(iOS 26.0, *) { "ellipsis" } else { "ellipsis.circle" }
    }

    static var moreFilled: String {
        if #available(iOS 26.0, *) { "ellipsis" } else { "ellipsis.circle.fill" }
    }

    static var isGlass: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }
}
