import UIKit

/// iPad 侧栏里列出的一个相簿（与侧栏同序）
struct SidebarAlbum: Equatable {
    let id: UUID
    let name: String
}

/// iPad：把照片拖到侧栏的相簿上 = 加入那个相簿。
///
/// 网格的长按拖动是自绘的（为了「一震动就能拖」，见 PhotoContextMenu.swift），不是系统拖放会话，
/// 系统给侧栏标签的拖放接口（UITabBarControllerDelegate 的 acceptItemsFromDropSession）用不上 ——
/// 自己找侧栏的行：侧栏是 `_UITabSidebarCollectionView`，每行 `_UITabSidebarCell`、无障碍标签即标题，
/// 「我的相簿」分组标题之后的行按顺序对应侧栏的相簿（再用名字核对）
@MainActor
enum SidebarAlbumTargets {
    struct Target {
        let albumID: UUID
        weak var cell: UIView?
        /// 窗口坐标
        let frame: CGRect
    }

    static let groupTitle = "我的相簿"

    /// 侧栏本身的范围（窗口坐标）：iPad 竖屏时侧栏盖在网格上，手指在这里就算离开了网格
    static func sidebarFrame(of targets: [Target]) -> CGRect {
        // 相簿行所在的列表（iOS 26 是 _UITabSidebarCollectionView，iOS 18 类名不同 —— 按类型找，不认类名）
        var view = targets.first?.cell?.superview
        while let current = view, !(current is UICollectionView) {
            view = current.superview
        }
        return view.map { $0.convert($0.bounds, to: nil) } ?? .null
    }

    /// 行的标题：iOS 26 在无障碍标签上；iOS 18 的行没有无障碍标签，读行里的文字标签
    private static func title(of cell: UIView) -> String? {
        if let label = cell.accessibilityLabel, !label.isEmpty {
            return label
        }
        func firstLabel(in view: UIView) -> String? {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                return text
            }
            for subview in view.subviews {
                if let text = firstLabel(in: subview) { return text }
            }
            return nil
        }
        return firstLabel(in: cell)
    }

    static func find(in window: UIWindow, albums: [SidebarAlbum]) -> [Target] {
        guard !albums.isEmpty else { return [] }
        var cells: [UIView] = []
        func walk(_ view: UIView) {
            if view.isHidden || view.alpha < 0.01 { return }
            if String(describing: type(of: view)).contains("TabSidebarCell") {
                cells.append(view)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        let ordered = cells
            .map { ($0, $0.convert($0.bounds, to: nil)) }
            .filter { $0.1.width > 1 && window.bounds.intersects($0.1) }
            .sorted { $0.1.minY < $1.1.minY }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SIDEBAR_DROP"] != nil {
        print("SIDEBAR_FIND cells=\(cells.count) visible=\(ordered.count) labels=\(ordered.map { title(of: $0.0) ?? "-" })")
        }
        #endif
        guard let header = ordered.firstIndex(where: { title(of: $0.0) == groupTitle }) else { return [] }
        var targets: [Target] = []
        var remaining = albums
        for (cell, frame) in ordered[(header + 1)...] {
            guard let label = title(of: cell) else { continue }
            // 按顺序对应，名字对不上时按名字找（相簿列表刚变过、侧栏还没刷新）
            let index = remaining.first?.name == label ? 0 : remaining.firstIndex { $0.name == label }
            guard let index else { continue }
            targets.append(Target(albumID: remaining[index].id, cell: cell, frame: frame))
            remaining.remove(at: index)
        }
        return targets
    }
}

/// 悬停在能加入的相簿行上时，盖在那一行上的强调色圆角底（系统行的高亮在玻璃侧栏上只是文字变灰，看不出来）
final class SidebarDropHighlightView: UIView {
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.tintColor.withAlphaComponent(0.18)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 2
        layer.borderColor = UIColor.tintColor.withAlphaComponent(0.6).cgColor
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(on frame: CGRect?) {
        if let frame {
            if alpha == 0 {
                self.frame = frame
            }
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState]) {
                self.frame = frame
                self.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState]) {
                self.alpha = 0
            }
        }
    }
}

/// 拖动中浮在最上层、跟着手指走的照片（越过网格边界飞到侧栏）。
/// 悬停在能加入的相簿上时缩小一点、右上角出现「+」
final class DragGhostView: UIView {
    private let imageView = UIImageView()
    private let badge = UIImageView()
    private(set) var showsBadge = false

    init(image: UIImage?, frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)

        badge.image = UIImage(systemName: "plus.circle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold))
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(paletteColors: [.white, .systemGreen])
        badge.backgroundColor = .white
        badge.layer.cornerRadius = 15
        badge.clipsToBounds = true
        badge.sizeToFit()
        badge.frame.size = CGSize(width: 30, height: 30)
        badge.alpha = 0
        badge.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        badge.center = CGPoint(x: bounds.maxX - 4, y: bounds.minY + 4)
    }

    /// 悬停在能加入的相簿上：缩小、出现「+」；离开：恢复
    func setDropping(_ dropping: Bool) {
        guard dropping != showsBadge else { return }
        showsBadge = dropping
        if dropping {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = dropping ? CGAffineTransform(scaleX: 0.72, y: 0.72) : .identity
            self.badge.alpha = dropping ? 1 : 0
            // 「+」不随照片一起缩小：反向放大抵消
            self.badge.transform = dropping ? CGAffineTransform(scaleX: 1 / 0.72, y: 1 / 0.72) : CGAffineTransform(scaleX: 0.5, y: 0.5)
        }
    }

    /// 放进相簿：飞进那一行、缩小淡出
    func fly(into frame: CGRect, completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseIn]) {
            self.center = CGPoint(x: frame.minX + 40, y: frame.midY)
            self.transform = CGAffineTransform(scaleX: 0.15, y: 0.15)
            self.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            completion()
        }
    }

    /// 没放进相簿：落回格子原位
    func fly(back frame: CGRect, completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.transform = .identity
            self.badge.alpha = 0
            self.bounds.size = frame.size
            self.center = CGPoint(x: frame.midX, y: frame.midY)
            self.layer.shadowOpacity = 0
        } completion: { _ in
            self.removeFromSuperview()
            completion()
        }
    }
}
