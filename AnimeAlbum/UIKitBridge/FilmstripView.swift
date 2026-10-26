import SwiftUI
import UIKit

/// 查看器底部胶片条（UICollectionView + 自定义布局）。
///
/// 不用 SwiftUI ScrollView + LazyHStack：排版宽度变化与滚动动画同时进行时它的行为不可控 ——
/// 叠放用的 zIndex 一变就停在旧排版（实测），排版变化与 scrollTo 两个动画各算各的，真机上来回跳。
/// 这里每格的位置、层级、滚动偏移全由布局算出，排版变化和滚动放在同一个 UIView 动画里。
///
/// 排版规则（按「锚点张」排）：普通照片之间 2pt，锚点张展开为原始比例、两侧各再空 4pt；
/// 多页 PDF 叠成一组 —— 锚点所在的 PDF 只有锚点页完整露出、压在最上面，往左往右依次一页压一页、
/// 每页只露出 9pt，整组两侧空 5pt；其余 PDF 以首页为顶叠放。
/// 拖动胶片条期间锚点冻结（排版不动，只换翻页器的页），松手停下后才换成当前张并对正 ——
/// 若随拖动实时重排，手指下的内容跟着移动、又换了一张，来回跳
struct FilmstripView: UIViewRepresentable {
    let items: [ViewerItem]
    let index: Int
    var onSelect: (Int) -> Void

    static let height: CGFloat = 52
    static let itemSize = CGSize(width: 28, height: 40)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let layout = FilmstripLayout()
        let collectionView = FilmstripCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.decelerationRate = .fast
        collectionView.delegate = coordinator
        collectionView.dataSource = coordinator
        collectionView.register(FilmstripCell.self, forCellWithReuseIdentifier: "cell")
        collectionView.onBoundsSizeChange = { [weak coordinator] in coordinator?.boundsSizeChanged() }
        coordinator.collectionView = collectionView
        coordinator.layout = layout
        #if DEBUG
        NotificationCenter.default.addObserver(forName: .filmstripDebugScrub, object: nil, queue: .main) { [weak coordinator] note in
            MainActor.assumeIsolated { coordinator?.debugScrub(by: note.object as? Int ?? 5) }
        }
        #endif
        layout.items = items
        layout.anchorIndex = index
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(with: self)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private var parent: FilmstripView
        weak var collectionView: FilmstripCollectionView?
        weak var layout: FilmstripLayout?
        /// 用户拖动 / 惯性滚动中（排版冻结）
        private var isScrubbing = false
        /// 最近一次因拖动上报的页码：外部 index 等于它时不是外部换页
        private var reportedIndex: Int

        init(_ parent: FilmstripView) {
            self.parent = parent
            reportedIndex = parent.index
        }

        func update(with parent: FilmstripView) {
            let old = self.parent
            self.parent = parent
            guard let collectionView, let layout else { return }
            if old.items != parent.items {
                layout.items = parent.items
                layout.anchorIndex = min(parent.index, parent.items.count - 1)
                reportedIndex = parent.index
                collectionView.reloadData()
                collectionView.layoutIfNeeded()
                center(animated: false)
                return
            }
            guard parent.index != layout.anchorIndex, !isScrubbing else { return }
            // 翻页器换页 / 点了某格：重排 + 对正，同一个动画
            reportedIndex = parent.index
            relayout(anchor: parent.index, animated: true)
        }

        func boundsSizeChanged() {
            guard let collectionView else { return }
            let half = collectionView.bounds.width / 2
            collectionView.contentInset = UIEdgeInsets(top: 0, left: half, bottom: 0, right: half)
            center(animated: false)
        }

        private func relayout(anchor: Int, animated: Bool) {
            guard let collectionView, let layout else { return }
            let apply = {
                layout.anchorIndex = anchor
                layout.invalidateLayout()
                collectionView.layoutIfNeeded()
                collectionView.contentOffset = self.centeredOffset()
            }
            if animated {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: apply)
            } else {
                apply()
            }
        }

        private func center(animated: Bool) {
            relayout(anchor: layout?.anchorIndex ?? parent.index, animated: animated)
        }

        /// 锚点张的格子中心对准条的正中
        private func centeredOffset() -> CGPoint {
            guard let collectionView, let layout,
                  let frame = layout.slotFrame(at: layout.anchorIndex, in: collectionView)
            else {
                return collectionView?.contentOffset ?? .zero
            }
            return CGPoint(x: frame.midX - collectionView.bounds.width / 2, y: 0)
        }

        // MARK: 拖动

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isScrubbing = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isScrubbing, let collectionView, let layout else { return }
            // 正中那一格就是当前张（排版冻结，只换翻页器的页）
            let midX = collectionView.contentOffset.x + collectionView.bounds.width / 2
            guard let index = layout.slotIndex(atX: midX, in: collectionView), index != reportedIndex else { return }
            reportedIndex = index
            parent.onSelect(index)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                endScrubbing()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            endScrubbing()
        }

        /// 停下后按当前张重排并对正
        private func endScrubbing() {
            guard isScrubbing else { return }
            isScrubbing = false
            relayout(anchor: reportedIndex, animated: true)
        }

        #if DEBUG
        /// FILMSTRIP_SCRUB=n：模拟一次拖动（同一套开始 / 滚动 / 结束处理）：1.2s 内向后滑过 n 格再松手
        func debugScrub(by steps: Int) {
            guard let collectionView else { return }
            scrollViewWillBeginDragging(collectionView)
            let start = collectionView.contentOffset.x
            let distance = CGFloat(steps) * 12
            let began = CACurrentMediaTime()
            var last = began
            let link = DebugDisplayLink { [weak self, weak collectionView] link in
                guard let self, let collectionView else { link.stop(); return }
                let now = CACurrentMediaTime()
                if now - last > 0.025 {
                    print(String(format: "FILMSTRIP_HITCH %.0fms at t=%.2f", (now - last) * 1000, now - began))
                }
                last = now
                let t = min((CACurrentMediaTime() - began) / 1.2, 1)
                collectionView.contentOffset.x = start + distance * t
                if t >= 1 {
                    link.stop()
                    self.scrollViewDidEndDragging(collectionView, willDecelerate: false)
                }
            }
            link.start()
        }
        #endif

        // MARK: 数据

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! FilmstripCell
            let item = parent.items[indexPath.item]
            cell.configure(item: item, isPage: item.page != nil && item.pageCount > 1)
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            reportedIndex = indexPath.item
            parent.onSelect(indexPath.item)
            relayout(anchor: indexPath.item, animated: true)
        }
    }
}

final class FilmstripCollectionView: UICollectionView {
    var onBoundsSizeChange: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onBoundsSizeChange?()
        }
    }
}

/// 胶片条布局：按锚点张算每格的占位（slot）与显示框（叠放的页显示框大于占位，溢出部分压在相邻格下面）
final class FilmstripLayout: UICollectionViewLayout {
    var items: [ViewerItem] = []
    var anchorIndex = 0

    private static let gap: CGFloat = 1
    private static let currentGap: CGFloat = 5
    private static let stackStep: CGFloat = 9

    private var slots: [CGRect] = []
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var contentWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let size = FilmstripView.itemSize
        let y = (collectionView.bounds.height - size.height) / 2
        let anchor = items.indices.contains(anchorIndex) ? items[anchorIndex] : nil
        var x: CGFloat = 0
        slots = []
        attributes = []
        for (index, item) in items.enumerated() {
            let expanded = index == anchorIndex
            let width = expanded
                ? min(max(size.height * item.aspectRatio, size.width), size.height * 1.8)
                : size.width
            let attribute = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            if let page = item.page, item.pageCount > 1 {
                let isAnchorGroup = item.photoID == anchor?.photoID
                let top = isAnchorGroup ? (anchor?.page ?? 0) : 0
                let groupGap = isAnchorGroup ? Self.currentGap : Self.gap
                if page == 0 { x += groupGap }
                let slotWidth = page == top ? width : Self.stackStep
                let slot = CGRect(x: x, y: y, width: slotWidth, height: size.height)
                // 顶页左边的页露左侧（向右溢出），右边的露右侧（向左溢出），都压在离顶页更近的那页下面
                let frameX = page <= top ? slot.minX : slot.maxX - width
                attribute.frame = CGRect(x: frameX, y: y, width: width, height: size.height)
                attribute.zIndex = -abs(page - top)
                slots.append(slot)
                x = slot.maxX
                if page == item.pageCount - 1 { x += groupGap }
            } else {
                let gap = expanded ? Self.currentGap : Self.gap
                x += gap
                let slot = CGRect(x: x, y: y, width: width, height: size.height)
                attribute.frame = slot
                attribute.zIndex = expanded ? 1 : 0
                slots.append(slot)
                x = slot.maxX + gap
            }
            attributes.append(attribute)
        }
        contentWidth = x
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: collectionView?.bounds.height ?? FilmstripView.height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.height != collectionView?.bounds.height
    }

    /// 占位框（滚动坐标系）
    func slotFrame(at index: Int, in collectionView: UICollectionView) -> CGRect? {
        slots.indices.contains(index) ? slots[index] : nil
    }

    /// 占位包含 x 的那一格（滚动坐标系）；落在格间空隙时取最近的
    func slotIndex(atX x: CGFloat, in collectionView: UICollectionView) -> Int? {
        guard !slots.isEmpty else { return nil }
        let frames = slots
        if let hit = frames.firstIndex(where: { $0.minX <= x && x < $0.maxX }) {
            return hit
        }
        return frames.indices.min { abs(frames[$0].midX - x) < abs(frames[$1].midX - x) }
    }
}

private final class FilmstripCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var itemID: ViewerItem.ID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0.5, height: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: ViewerItem, isPage: Bool) {
        // 叠放的 PDF 页加一道阴影，看得出页与页的边界
        layer.shadowOpacity = isPage ? 0.35 : 0
        guard item.id != itemID else { return }
        itemID = item.id
        loadTask?.cancel()
        if let cached = item.cachedImage(.tiny) ?? item.cachedImage(.small) {
            imageView.image = cached
            return
        }
        imageView.image = nil
        loadTask = Task { [weak self] in
            let image = await item.image(.tiny)
            guard let self, !Task.isCancelled, self.itemID == item.id else { return }
            self.imageView.image = image
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }
}

#if DEBUG
extension Notification.Name {
    static let filmstripDebugScrub = Notification.Name("FilmstripDebugScrub")
}
#endif
