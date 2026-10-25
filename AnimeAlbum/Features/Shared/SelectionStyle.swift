import SwiftUI

/// 勾选态的统一样式（UIKit 照片网格与 SwiftUI 相簿卡片共用，两边看起来必须一致）
enum SelectionStyle {
    /// 选中照片上的白色薄罩：提示「已选」又不遮住内容
    static let overlayOpacity: CGFloat = 0.2
    static let badgeDiameter: CGFloat = 22
    static let badgeRingWidth: CGFloat = 1.5
    static let badgeInset: CGFloat = 5
}

/// 右下角选中徽标：强调色实心圆 + 白色细环 + 轻投影，在浅色、深色照片上都清晰可辨
struct SelectionBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: SelectionStyle.badgeDiameter * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: SelectionStyle.badgeDiameter, height: SelectionStyle.badgeDiameter)
            .background(Circle().fill(.tint))
            .overlay(Circle().strokeBorder(.white, lineWidth: SelectionStyle.badgeRingWidth))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
