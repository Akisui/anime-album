import UIKit

/// 滑动连选手势（DESIGN.md §6.2）：图库选择模式与「添加到相簿」选择器共用，交互对齐系统照片：
/// - 从某张照片上**横向**起手拖动进入连选，之后手指可上下移动跨行。起点到当前点之间
///   （按网格顺序）的照片统一设为「起点的反状态」，划出范围的照片恢复起手前的状态（往回划即撤销）；
/// - 手指靠近可见区域上下边缘时自动滚屏，越深入边缘越快；
/// - **纵向**起手仍是普通滚动：滚动手势等本手势判定失败才开始，两者阈值相同，无可感知延迟。
///
/// 挂在网格所在的 UIScrollView（UICollectionView）上。坐标一律用窗口坐标，
/// 「窗口坐标 → 网格序号」的命中测试由宿主网格提供。
@MainActor
final class SwipeSelectionController: NSObject {
    /// 网格顺序的照片 ID
    var itemIDs: [UUID] = []
    /// 当前选中集（宿主每次更新时同步进来）
    var selection: Set<UUID> = []
    var onSelectionChange: (Set<UUID>) -> Void = { _ in }
    /// 窗口坐标 → 网格序号。exact 为 true 时只认手指正下方的格子（起手判定），否则取最近的格子
    var itemIndex: (_ point: CGPoint, _ exact: Bool) -> Int? = { _, _ in nil }
    /// 网格未被 bar 遮挡的可见区域（窗口坐标）；返回 nil 时按滚动视图的 adjustedContentInset 计算
    var visibleRect: () -> CGRect? = { nil }
    /// 关闭时手势不接收触摸，滚动不必等它判定（非选择模式下完全不参与）
    var isEnabled = true {
        didSet { recognizer.isEnabled = isEnabled }
    }

    private let recognizer = UIPanGestureRecognizer()
    private weak var scrollView: UIScrollView?

    /// 一次连选手势的状态
    private struct Session {
        /// 起点照片的网格序号
        let anchor: Int
        /// 范围内照片统一设为的状态（= 起点照片的反状态）
        let selecting: Bool
        /// 起手前的选中集：划出范围的照片恢复成它
        let baseline: Set<UUID>
        var current: Int
    }

    private var session: Session?

    private var autoScrollLink: CADisplayLink?
    /// 自动滚屏速度（pt/s），负值向上
    private var autoScrollVelocity: CGFloat = 0
    private var lastAutoScrollTimestamp: CFTimeInterval?

    /// 触发自动滚屏的边缘带高度与最高速度
    private static let autoScrollEdge: CGFloat = 72
    private static let autoScrollMaxSpeed: CGFloat = 1400

    override init() {
        super.init()
        recognizer.addTarget(self, action: #selector(handlePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
    }

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        scrollView.addGestureRecognizer(recognizer)
        scrollView.panGestureRecognizer.require(toFail: recognizer)
    }

    func detach() {
        stopAutoScroll()
        session = nil
        recognizer.view?.removeGestureRecognizer(recognizer)
        scrollView = nil
    }

    // MARK: 手势

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard let anchor = itemIndex(touchDownLocation, true) else { return }
            begin(anchor: anchor)
            continueSwipe()
        case .changed:
            continueSwipe()
        default:
            session = nil
            stopAutoScroll()
        }
    }

    /// 手势在 .began 时已移动过判定阈值，起点 = 当前位置 - 位移
    private var touchDownLocation: CGPoint {
        let location = recognizer.location(in: nil)
        let translation = recognizer.translation(in: nil)
        return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }

    private func begin(anchor: Int) {
        guard itemIDs.indices.contains(anchor) else { return }
        session = Session(
            anchor: anchor, selecting: !selection.contains(itemIDs[anchor]), baseline: selection, current: anchor)
        applyRange()
    }

    /// 按手指当前位置更新范围与自动滚屏速度。手指移出可见区域（压在导航栏 / Tab 栏上）时
    /// 先夹回可见区域再命中 —— 只在真正可见的格子里找，范围停在边缘那一行，由自动滚屏继续扩展
    private func continueSwipe() {
        guard session != nil else { return }
        let location = recognizer.location(in: nil)
        if let index = itemIndex(clampedToVisible(location), false), index != session?.current {
            session?.current = index
            applyRange()
        }
        updateAutoScroll(for: location)
    }

    /// 每次从 baseline 重算：范围内设为目标状态，范围外恢复原状
    private func applyRange() {
        guard let session, !itemIDs.isEmpty else { return }
        let lower = max(0, min(session.anchor, session.current))
        let upper = min(itemIDs.count - 1, max(session.anchor, session.current))
        guard lower <= upper else { return }

        var result = session.baseline
        for id in itemIDs[lower...upper] {
            if session.selecting {
                result.insert(id)
            } else {
                result.remove(id)
            }
        }
        guard result != selection else { return }
        selection = result
        onSelectionChange(result)
    }

    // MARK: 可见区域

    private var currentVisibleRect: CGRect? {
        if let rect = visibleRect(), !rect.isEmpty {
            return rect
        }
        guard let scrollView, scrollView.window != nil else { return nil }
        return scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: nil)
    }

    private func clampedToVisible(_ point: CGPoint) -> CGPoint {
        guard let visible = currentVisibleRect else { return point }
        return CGPoint(
            x: min(max(point.x, visible.minX + 1), visible.maxX - 1),
            y: min(max(point.y, visible.minY + 1), visible.maxY - 1))
    }

    // MARK: 自动滚屏

    /// 手指进入可见区域上下边缘带（或越过边缘）时滚屏：速度按深入程度平方增长，
    /// 刚碰到边缘时很慢、便于精确停在某一行，推到底则快速翻过整屏
    private func updateAutoScroll(for point: CGPoint) {
        guard let visible = currentVisibleRect else { return }
        let edge = min(Self.autoScrollEdge, visible.height / 4)
        let depth: CGFloat
        if point.y < visible.minY + edge {
            depth = -min((visible.minY + edge - point.y) / edge, 1)
        } else if point.y > visible.maxY - edge {
            depth = min((point.y - (visible.maxY - edge)) / edge, 1)
        } else {
            depth = 0
        }
        autoScrollVelocity = depth * abs(depth) * Self.autoScrollMaxSpeed

        if autoScrollVelocity == 0 {
            stopAutoScroll()
        } else if autoScrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
            lastAutoScrollTimestamp = nil
        }
    }

    @objc private func autoScrollTick(_ link: CADisplayLink) {
        guard let scrollView, session != nil else {
            stopAutoScroll()
            return
        }
        defer { lastAutoScrollTimestamp = link.timestamp }
        guard let last = lastAutoScrollTimestamp else { return }
        let elapsed = min(link.timestamp - last, 1.0 / 30)

        let insets = scrollView.adjustedContentInset
        let minY = -insets.top
        let maxY = max(minY, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
        let currentY = scrollView.contentOffset.y
        let nextY = min(max(currentY + autoScrollVelocity * CGFloat(elapsed), minY), maxY)
        guard nextY != currentY else { return }
        scrollView.contentOffset.y = nextY
        // 手指不动、内容在动：同一屏幕位置下的格子变了，重新命中以扩展范围
        continueSwipe()
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollVelocity = 0
        lastAutoScrollTimestamp = nil
    }

    #if DEBUG
    /// 模拟一次从第 start 张到第 end 张的连选（模拟器无法注入触摸，走同一套范围逻辑）
    func debugSimulate(from start: Int, to end: Int, after delay: Duration = .seconds(1.5)) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.isEnabled,
                  self.itemIDs.indices.contains(start), self.itemIDs.indices.contains(end)
            else {
                return
            }
            self.begin(anchor: start)
            for index in stride(from: start, through: end, by: start <= end ? 1 : -1) {
                self.session?.current = index
                self.applyRange()
                try? await Task.sleep(for: .milliseconds(60))
            }
            self.session = nil
        }
    }
    #endif
}

// MARK: - 手势仲裁（横向起手 = 连选，纵向起手 = 滚动）

extension SwipeSelectionController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled, gestureRecognizer === recognizer else { return false }
        let translation = recognizer.translation(in: nil)
        guard abs(translation.x) > abs(translation.y) else { return false }
        return itemIndex(touchDownLocation, true) != nil
    }
}

// MARK: - UICollectionView 命中测试

extension UICollectionView {
    /// 窗口坐标 → 格子序号（单 section）。exact 为 false 时落在格子间隙也取最近的已布局格子
    func itemIndex(atWindowPoint windowPoint: CGPoint, exact: Bool) -> Int? {
        let point = convert(windowPoint, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            return indexPath.item
        }
        guard !exact else { return nil }
        let cells = (collectionViewLayout.layoutAttributesForElements(in: bounds) ?? [])
            .filter { $0.representedElementCategory == .cell }
        return cells.min { $0.frame.distanceSquared(to: point) < $1.frame.distanceSquared(to: point) }?
            .indexPath.item
    }
}

extension CGRect {
    /// 点到矩形的最短距离平方（点在矩形内为 0）：滑动连选取「最近的格子」用
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = Swift.max(minX - point.x, 0, point.x - maxX)
        let dy = Swift.max(minY - point.y, 0, point.y - maxY)
        return dx * dx + dy * dy
    }
}
