import UIKit

/// UIKit 照片网格共用的 compositional layout：正方形单元、间距 2pt（DESIGN.md §6.1），
/// 列数按可用宽度与目标单元尺寸自适应。
enum PhotoGridLayout {
    static let spacing: CGFloat = 2

    static func make(cellTarget: CGFloat, footerHeight: CGFloat? = nil) -> PhotoGridCompositionalLayout {
        make(footerHeight: footerHeight) { width in
            Int((width + spacing) / (cellTarget + spacing))
        }
    }

    /// 固定列数（如一行 15 张的最密档）
    static func make(columns: Int, footerHeight: CGFloat? = nil) -> PhotoGridCompositionalLayout {
        make(footerHeight: footerHeight) { _ in columns }
    }

    private static func make(
        footerHeight: CGFloat?, columnsForWidth: @escaping (CGFloat) -> Int
    ) -> PhotoGridCompositionalLayout {
        PhotoGridCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(1, columnsForWidth(width))
            let itemWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)

            // item 宽度必须 .absolute 显式指定：repeatingSubitem 不会均分 fractionalWidth(1) 的 item
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .absolute(itemWidth), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .absolute(itemWidth)),
                repeatingSubitem: item,
                count: columns)
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            if let footerHeight {
                section.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1), heightDimension: .absolute(footerHeight)),
                        elementKind: UICollectionView.elementKindSectionFooter,
                        alignment: .bottom),
                ]
            }
            return section
        }
    }
}

/// 可指定「目标滚动位置」的布局：交互式换档落定 / 退回时，系统会向新 / 旧布局要目标偏移并直接设上，
/// 默认值与我们按焦点算的不同 —— 落定那一帧画面会跳（实测差约 0.7 行）
protocol TargetOffsetOverriding: UICollectionViewLayout {
    var targetOffsetOverride: CGPoint? { get set }
}

final class PhotoGridCompositionalLayout: UICollectionViewCompositionalLayout, TargetOffsetOverriding {
    var targetOffsetOverride: CGPoint?

    /// 长按排序中被拖的格子：放大浮起、置顶（阴影由格子按 zIndex 显示）
    static let liftedZIndex = 1000

    override func layoutAttributesForInteractivelyMovingItem(
        at indexPath: IndexPath, withTargetPosition position: CGPoint
    ) -> UICollectionViewLayoutAttributes {
        let attributes = super.layoutAttributesForInteractivelyMovingItem(at: indexPath, withTargetPosition: position)
        attributes.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        attributes.zIndex = Self.liftedZIndex
        return attributes
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        targetOffsetOverride ?? super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
    }

    /// 页脚（「N 张照片」）出现时不淡入：换档交接时系统会把它当新元素淡入，画面上闪一帧空白
    override func initialLayoutAttributesForAppearingSupplementaryElement(
        ofKind elementKind: String, at elementIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForSupplementaryView(ofKind: elementKind, at: elementIndexPath)
    }
}

/// 一行一张、按原始比例的单列布局（最疏档）：宽度铺满，高度 = 宽 ÷ 宽高比，不裁成正方形。
/// 极端比例夹在 0.25～3 倍宽之间（超长图仍按比例显示在格子里，只是格子不再无限高）
final class PhotoAspectListLayout: UICollectionViewLayout, TargetOffsetOverriding {
    var targetOffsetOverride: CGPoint?
    /// 照片宽高比（宽 / 高），按网格顺序；由网格在数据变化时更新
    var aspectRatios: [CGFloat] = [] {
        didSet { invalidateLayout() }
    }

    private static let footerHeight: CGFloat = 64
    private var frames: [CGRect] = []
    private var footerFrame: CGRect = .zero
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        let count = collectionView.numberOfItems(inSection: 0)
        frames.removeAll(keepingCapacity: true)
        var y: CGFloat = 0
        for item in 0..<count {
            let ratio = item < aspectRatios.count && aspectRatios[item] > 0 ? aspectRatios[item] : 1
            let height = min(max(width / ratio, width * 0.25), width * 3)
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height + PhotoGridLayout.spacing
        }
        if count > 0 {
            y -= PhotoGridLayout.spacing
        }
        footerFrame = CGRect(x: 0, y: y, width: width, height: Self.footerHeight)
        contentHeight = y + Self.footerHeight
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // 二分找到第一个底边进入 rect 的格子，往后取到顶边越过 rect 为止
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxY < rect.minY {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var item = low
        while item < frames.count, frames[item].minY <= rect.maxY {
            if let attributes = layoutAttributesForItem(at: IndexPath(item: item, section: 0)) {
                result.append(attributes)
            }
            item += 1
        }
        if footerFrame.intersects(rect),
           let footer = layoutAttributesForSupplementaryView(
               ofKind: UICollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: 0)) {
            result.append(footer)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard elementKind == UICollectionView.elementKindSectionFooter else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        attributes.frame = footerFrame
        return attributes
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        targetOffsetOverride ?? super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
    }

    override func initialLayoutAttributesForAppearingSupplementaryElement(
        ofKind elementKind: String, at elementIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForSupplementaryView(ofKind: elementKind, at: elementIndexPath)
    }
}

/// 可选「底部锚定」的网格：进入时定位到最新照片（列表底部），内容不满一屏时仍从顶部排
final class BottomAnchoredCollectionView: UICollectionView {
    var anchorsToBottom = true
    private var didAnchor = false

    private var maxOffsetY: CGFloat {
        let insets = adjustedContentInset
        return max(-insets.top, contentSize.height + insets.bottom - bounds.height)
    }

    var isAtBottom: Bool {
        contentOffset.y >= maxOffsetY - 2
    }

    func scrollToBottom(animated: Bool) {
        setContentOffset(CGPoint(x: contentOffset.x, y: maxOffsetY), animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard anchorsToBottom, !didAnchor, bounds.height > 0, contentSize.height > 0 else { return }
        didAnchor = true
        contentOffset.y = maxOffsetY
    }
}

/// 捏合换档的过渡布局（原生相册式：**方块缩放，照片原地淡入淡出，不飞**）。
///
/// 关键事实：同一时刻新旧两套网格的格子尺寸相同、都贴左边缘、都对齐焦点行，所以两套网格的
/// 格子位置完全重合 —— 只是每个格子里放的照片不同。于是过渡 = 一张随进度缩放的方块网格，
/// 每个方块里旧照片淡出、新照片淡入：
/// - 本布局把网格（真实格子）从一开始就按**新列数**排在这些方块上，尺寸随进度在新旧格子尺寸间变化；
/// - 旧照片由调用方用一层覆盖（PinchCrossfadeOverlay，背景透明）画在同样的方块位置上，逐格决定透明度：
///   新旧都有照片 → 原地交叉淡化；只有旧照片且换档结束时已移出屏幕（放大时右侧的列）→ 保持实色移出去；
///   只有旧照片但结束时仍在屏内 → 淡出；只有新照片且开始时在屏外（缩小时从边缘进来）→ 直接显示；
///   只有新照片但开始时就在屏内 → 淡入。即：靠边进出的照片不渐变、不留白（用户要求），
///   原地凭空出现 / 消失的才淡。
/// 弃用过的做法（都让照片满屏飞或重影）：系统默认插值、整层快照绕手指缩放 + 交叉淡化、
/// 新旧位置逐格插值、半程重排时滑到新位置。
final class PhotoGridZoomTransitionLayout: UICollectionViewTransitionLayout {
    struct Geometry {
        var fromOffsetY: CGFloat
        var toOffsetY: CGFloat
        /// 焦点格子中心在视口里的 Y（旧 / 新布局各自，新布局可能因夹在可滚动范围内而不同）
        var fromAnchorY: CGFloat
        var toAnchorY: CGFloat
        var fromCellSize: CGFloat
        var toCellSize: CGFloat
        var fromColumns: Int
        var toColumns: Int
        var focusItem: Int
        var itemCount: Int
        var viewport: CGRect
        /// 手指（捏合中心）在视口里的位置：纵向缩放以它的高度为中心
        var finger: CGPoint
    }

    var geometry: Geometry?

    /// 旧新照片交叉淡化的进度曲线（前段只缩放，30%～80% 间完成）
    static func crossfade(_ progress: CGFloat) -> CGFloat {
        smoothstep(0.3, 0.8, progress)
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    override var collectionViewContentSize: CGSize {
        let from = currentLayout.collectionViewContentSize
        let to = nextLayout.collectionViewContentSize
        let p = transitionProgress
        return CGSize(width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
    }

    /// 过渡中系统按这个值改写滚动偏移：必须与我们按进度设的一致，否则两边打架、画面错位
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let geometry else { return super.targetContentOffset(forProposedContentOffset: proposedContentOffset) }
        return CGPoint(x: 0, y: State(progress: transitionProgress, geometry: geometry).offsetY)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let geometry else { return super.layoutAttributesForElements(in: rect) }
        let state = State(progress: transitionProgress, geometry: geometry)
        let originY = viewportOriginY(state)
        var result = state.indices(columns: geometry.toColumns, top: rect.minY - originY, bottom: rect.maxY - originY)
            .compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
            .filter { $0.frame.intersects(rect) }
        if let footer = layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: 0)),
           footer.frame.intersects(rect) {
            result.append(footer)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let geometry else { return super.layoutAttributesForItem(at: indexPath) }
        let state = State(progress: transitionProgress, geometry: geometry)
        let origin = state.origin(of: indexPath.item, columns: geometry.toColumns)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(
            x: origin.x, y: origin.y + viewportOriginY(state), width: state.cellSize, height: state.cellSize)
        // 只有新照片、且开始时就在屏内的方块（原地凭空出现）才淡入；其余实色（有旧照片的由覆盖层盖着交叉淡化）
        if Self.counterpart(of: indexPath.item, from: geometry.toColumns, to: geometry.fromColumns, geometry) == nil,
           isOnScreen(item: indexPath.item, columns: geometry.toColumns, progress: 0, geometry) {
            attributes.alpha = Self.crossfade(transitionProgress)
        }
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let from = currentLayout.layoutAttributesForSupplementaryView(ofKind: elementKind, at: indexPath),
              let to = nextLayout.layoutAttributesForSupplementaryView(ofKind: elementKind, at: indexPath),
              let attributes = from.copy() as? UICollectionViewLayoutAttributes
        else {
            return nil
        }
        let p = transitionProgress
        attributes.frame = CGRect(
            x: from.frame.minX + (to.frame.minX - from.frame.minX) * p,
            y: from.frame.minY + (to.frame.minY - from.frame.minY) * p,
            width: from.frame.width + (to.frame.width - from.frame.width) * p,
            height: from.frame.height + (to.frame.height - from.frame.height) * p)
        return attributes
    }

    /// 旧照片在当前进度下所在方块的视口坐标与透明度（供覆盖层逐格绘制）：按**旧列数**排在同一套方块上
    func previousItems() -> [(item: Int, frame: CGRect, alpha: CGFloat)] {
        guard let geometry else { return [] }
        let state = State(progress: transitionProgress, geometry: geometry)
        let fade = Self.crossfade(transitionProgress)
        return state.indices(columns: geometry.fromColumns, top: 0, bottom: geometry.viewport.height).compactMap { item in
            let origin = state.origin(of: item, columns: geometry.fromColumns)
            let frame = CGRect(x: origin.x, y: origin.y, width: state.cellSize, height: state.cellSize)
            guard frame.intersects(geometry.viewport) else { return nil }
            // 方块里有新照片 → 交叉淡化；没有新照片：结束时仍在屏内（原地消失）才淡出，会移出屏幕的保持实色
            let hasNew = Self.counterpart(of: item, from: geometry.fromColumns, to: geometry.toColumns, geometry) != nil
            let fadesOut = hasNew || isOnScreen(item: item, columns: geometry.fromColumns, progress: 1, geometry)
            return (item, frame, fadesOut ? 1 - fade : 1)
        }
    }

    /// 同一方块在另一种列数下放的照片序号（没有则 nil）：两套网格方块重合、都以焦点行为基准
    private static func counterpart(of item: Int, from: Int, to: Int, _ geometry: Geometry) -> Int? {
        let column = item % from
        guard column < to else { return nil }
        let rowOffset = item / from - geometry.focusItem / from
        let row = geometry.focusItem / to + rowOffset
        guard row >= 0 else { return nil }
        let other = row * to + column
        return other < geometry.itemCount ? other : nil
    }

    /// 某张照片按某列数排时，在给定进度下的方块是否落在视口内
    private func isOnScreen(item: Int, columns: Int, progress: CGFloat, _ geometry: Geometry) -> Bool {
        let state = State(progress: progress, geometry: geometry)
        let origin = state.origin(of: item, columns: columns)
        return CGRect(x: origin.x, y: origin.y, width: state.cellSize, height: state.cellSize)
            .intersects(geometry.viewport)
    }

    // MARK: 几何

    /// 视口顶边的内容坐标：取滚动视图的**实际**偏移。过渡中系统可能改写我们设的偏移（实测差过 146pt），
    /// 格子若按「应有偏移」换算，屏幕上整体错位，落定时再被校正就是一跳；按实际偏移换算，
    /// 格子在屏幕上的位置始终是对的
    private func viewportOriginY(_ state: State) -> CGFloat {
        collectionView?.contentOffset.y ?? state.offsetY
    }

    /// 某一进度下的方块网格：格子尺寸、焦点格子中心在视口里的高度、第 0 列左边缘、对应的滚动偏移。
    /// - 纵向以手指高度为中心：焦点格子中心按缩放比例远离 / 靠近手指；若新布局的滚动位置被夹在
    ///   可滚动范围内，差值随进度线性补上，100% 时与新布局完全一致；
    /// - 横向始终贴左边缘。以手指为中心试过：网格最终必须左对齐成整列，落定前得横向挪回去，
    ///   在右侧放大就成了「先放大再右移」，很怪（用户否决）；缩小时还会在左侧留白
    private struct State {
        let geometry: Geometry
        let cellSize: CGFloat
        let anchorY: CGFloat
        let offsetY: CGFloat

        init(progress p: CGFloat, geometry: Geometry) {
            self.geometry = geometry
            cellSize = geometry.fromCellSize + (geometry.toCellSize - geometry.fromCellSize) * p
            offsetY = geometry.fromOffsetY + (geometry.toOffsetY - geometry.fromOffsetY) * p
            let scale = cellSize / geometry.fromCellSize
            let finalScale = geometry.toCellSize / geometry.fromCellSize
            let finger = geometry.finger
            let zoomedY = finger.y + (geometry.fromAnchorY - finger.y) * scale
            let finalZoomedY = finger.y + (geometry.fromAnchorY - finger.y) * finalScale
            anchorY = zoomedY + (geometry.toAnchorY - finalZoomedY) * p
        }

        private var pitch: CGFloat {
            cellSize + PhotoGridLayout.spacing
        }

        /// 按某个列数排列时，这格左上角在视口里的位置（左边缘 + 焦点行为不动点）。
        /// 两种列数共用同一套方块：格子尺寸、间距、左边缘、焦点行都相同
        func origin(of item: Int, columns: Int) -> CGPoint {
            let row = item / columns
            let focusRow = geometry.focusItem / columns
            return CGPoint(
                x: CGFloat(item % columns) * pitch,
                y: anchorY - cellSize / 2 + CGFloat(row - focusRow) * pitch)
        }

        /// 按某个列数排列时，与视口纵向区间 [top, bottom] 相交的格子序号
        func indices(columns: Int, top: CGFloat, bottom: CGFloat) -> IndexSet {
            let focusRow = geometry.focusItem / columns
            let firstRowTop = anchorY - cellSize / 2
            let firstRow = focusRow + Int(((top - firstRowTop) / pitch).rounded(.down)) - 1
            let lastRow = focusRow + Int(((bottom - firstRowTop) / pitch).rounded(.up)) + 1
            let lower = max(0, firstRow * columns)
            let upper = min(geometry.itemCount, (lastRow + 1) * columns)
            return lower < upper ? IndexSet(integersIn: lower..<upper) : IndexSet()
        }
    }
}

/// 正方形网格 ↔ 一行一张（按原始比例）之间的捏合过渡。两边形状不同、格子无法重合，
/// 不能用「方块缩放 + 原地交叉淡化」，改为：
/// - 捏住的那张（焦点）由覆盖层的焦点视图单独画、不淡化：从正方形平滑变成原始比例（或反过来）并移到
///   目标位置；aspectFill 显示，格子形状一变被裁掉的部分自然展开，不重影；
/// - 其余照片：旧布局一层（覆盖层，带不透明底）与新布局一层（真实格子）以焦点为中心按同一缩放量缩放，
///   旧层整体淡出（前段只缩放，30%～80% 间淡出）。
final class PhotoGridMorphTransitionLayout: UICollectionViewTransitionLayout {
    struct Geometry {
        var fromOffsetY: CGFloat
        var toOffsetY: CGFloat
        var focusItem: Int
        /// 焦点格子在旧 / 新布局里的视口坐标
        var fromFocus: CGRect
        var toFocus: CGRect
        var viewport: CGRect
    }

    var geometry: Geometry?

    override var collectionViewContentSize: CGSize {
        let from = currentLayout.collectionViewContentSize
        let to = nextLayout.collectionViewContentSize
        let p = transitionProgress
        return CGSize(width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let geometry else { return super.targetContentOffset(forProposedContentOffset: proposedContentOffset) }
        return CGPoint(x: 0, y: offsetY(geometry))
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let geometry else { return super.layoutAttributesForElements(in: rect) }
        let originY = viewportOriginY(geometry)
        let viewportRect = rect.offsetBy(dx: 0, dy: -originY)
        // 新布局里落进 rect 的格子：把 rect 反变换回新布局自己的视口，再换成它的内容坐标去查
        let source = inverse(viewportRect, scale: newScale(geometry), center: currentCenter(geometry),
                             reference: geometry.toFocus.center)
            .offsetBy(dx: 0, dy: geometry.toOffsetY).insetBy(dx: 0, dy: -geometry.viewport.height / 2)
        var result = (nextLayout.layoutAttributesForElements(in: source) ?? [])
            .filter { $0.representedElementCategory == .cell }
            .compactMap { layoutAttributesForItem(at: $0.indexPath) }
            .filter { $0.frame.intersects(rect) }
        if let footer = layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: 0)),
           footer.frame.intersects(rect) {
            result.append(footer)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let geometry, let to = nextLayout.layoutAttributesForItem(at: indexPath) else {
            return super.layoutAttributesForItem(at: indexPath)
        }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let viewportFrame = to.frame.offsetBy(dx: 0, dy: -geometry.toOffsetY)
        attributes.frame = transform(viewportFrame, scale: newScale(geometry), center: currentCenter(geometry),
                                     reference: geometry.toFocus.center)
            .offsetBy(dx: 0, dy: viewportOriginY(geometry))
        // 焦点由覆盖层的焦点视图画（变形过程不淡化），真实格子先隐藏
        attributes.alpha = indexPath.item == geometry.focusItem ? 0 : 1
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let geometry, let to = nextLayout.layoutAttributesForSupplementaryView(ofKind: elementKind, at: indexPath),
              let attributes = to.copy() as? UICollectionViewLayoutAttributes
        else {
            return nil
        }
        let viewportFrame = to.frame.offsetBy(dx: 0, dy: -geometry.toOffsetY)
        attributes.frame = transform(viewportFrame, scale: newScale(geometry), center: currentCenter(geometry),
                                     reference: geometry.toFocus.center)
            .offsetBy(dx: 0, dy: viewportOriginY(geometry))
        return attributes
    }

    /// 旧布局一层在当前进度下的格子（视口坐标，不含焦点），供覆盖层绘制
    func previousItems() -> [(item: Int, frame: CGRect, alpha: CGFloat)] {
        guard let geometry else { return [] }
        let scale = oldScale(geometry)
        let center = currentCenter(geometry)
        let source = inverse(geometry.viewport, scale: scale, center: center, reference: geometry.fromFocus.center)
            .offsetBy(dx: 0, dy: geometry.fromOffsetY)
        return (currentLayout.layoutAttributesForElements(in: source) ?? [])
            .filter { $0.representedElementCategory == .cell && $0.indexPath.item != geometry.focusItem }
            .map { attributes in
                let viewportFrame = attributes.frame.offsetBy(dx: 0, dy: -geometry.fromOffsetY)
                return (attributes.indexPath.item,
                        transform(viewportFrame, scale: scale, center: center, reference: geometry.fromFocus.center), 1)
            }
    }

    /// 焦点照片当前的视口坐标：宽度随缩放、高度在正方形与原始比例之间过渡、中心从旧位置移到新位置
    func focusFrame() -> CGRect {
        guard let geometry else { return .zero }
        let p = transitionProgress
        let scale = oldScale(geometry)
        let width = geometry.fromFocus.width * scale
        let fromHeight = geometry.fromFocus.height * scale
        let toHeight = geometry.toFocus.height * scale / ratio(geometry)
        let height = fromHeight + (toHeight - fromHeight) * p
        let center = currentCenter(geometry)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    // MARK: 几何

    /// 新 / 旧焦点宽度比：旧层缩放从 1 走到它，新层缩放从它的倒数走到 1（两层缩放量始终一致）
    private func ratio(_ geometry: Geometry) -> CGFloat {
        geometry.toFocus.width / max(geometry.fromFocus.width, 1)
    }

    private func oldScale(_ geometry: Geometry) -> CGFloat {
        1 + (ratio(geometry) - 1) * transitionProgress
    }

    private func newScale(_ geometry: Geometry) -> CGFloat {
        oldScale(geometry) / ratio(geometry)
    }

    private func currentCenter(_ geometry: Geometry) -> CGPoint {
        let p = transitionProgress
        let from = geometry.fromFocus.center
        let to = geometry.toFocus.center
        return CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
    }

    private func offsetY(_ geometry: Geometry) -> CGFloat {
        geometry.fromOffsetY + (geometry.toOffsetY - geometry.fromOffsetY) * transitionProgress
    }

    /// 视口顶边的内容坐标取滚动视图的实际偏移（原因同 PhotoGridZoomTransitionLayout）
    private func viewportOriginY(_ geometry: Geometry) -> CGFloat {
        collectionView?.contentOffset.y ?? offsetY(geometry)
    }

    /// 以 reference 为基准缩放、再把 reference 移到 center
    private func transform(_ frame: CGRect, scale: CGFloat, center: CGPoint, reference: CGPoint) -> CGRect {
        CGRect(x: center.x + (frame.minX - reference.x) * scale,
               y: center.y + (frame.minY - reference.y) * scale,
               width: frame.width * scale, height: frame.height * scale)
    }

    private func inverse(_ frame: CGRect, scale: CGFloat, center: CGPoint, reference: CGPoint) -> CGRect {
        let inverseScale = 1 / max(scale, 0.0001)
        return CGRect(x: reference.x + (frame.minX - center.x) * inverseScale,
                      y: reference.y + (frame.minY - center.y) * inverseScale,
                      width: frame.width * inverseScale, height: frame.height * inverseScale)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

/// 捏合换档时盖在网格上的「旧照片层」：旧照片逐格画在与网格重合的方块上，逐格透明度由过渡布局给出
/// （`previousItems`）。背景透明 —— 没有旧照片的方块直接露出底下的新照片，任何时候都不留白。
/// 旧照片的图尚未进内存缓存时（缩小时从屏外进入视野的旧行）不画占位色：浅灰占位盖在新照片上淡化，
/// 看起来就是「发白」（实测）—— 先隐藏、异步加载好再显示
final class PinchCrossfadeOverlay: UIView {
    /// 旧照片所在的一层（整层透明度可调：网格 ↔ 一行一张时整层淡出）
    private let imageLayer = UIView()
    /// 焦点照片（网格 ↔ 一行一张时单独变形、不淡化），画在最上面
    private let focusView = UIImageView()
    private var imageViews: [Int: UIImageView] = [:]
    private var loadTasks: [Int: Task<Void, Never>] = [:]

    /// opaqueBackground：旧层带不透明底（整层淡出时用，进度 0 时完全盖住底下的新布局）
    init(frame: CGRect, opaqueBackground: Bool = false) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageLayer.backgroundColor = opaqueBackground ? .systemBackground : .clear
        addSubview(imageLayer)
        focusView.contentMode = .scaleAspectFill
        focusView.clipsToBounds = true
        focusView.isHidden = true
        addSubview(focusView)
    }

    var layerAlpha: CGFloat {
        get { imageLayer.alpha }
        set { imageLayer.alpha = newValue }
    }

    func setFocus(frame: CGRect, image: UIImage?) {
        focusView.isHidden = false
        focusView.frame = frame
        if let image, focusView.image !== image {
            focusView.image = image
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// items：旧照片序号、其方块的视口坐标与透明度；
    /// cachedImage：取该序号照片的已缓存缩略图（同步）；loadImage：缓存未命中时异步加载
    func update(
        items: [(item: Int, frame: CGRect, alpha: CGFloat)],
        cachedImage: (Int) -> UIImage?,
        loadImage: @escaping @Sendable (Int) async -> UIImage?
    ) {
        var visible = Set<Int>()
        for (item, frame, alpha) in items {
            visible.insert(item)
            let imageView: UIImageView
            if let existing = imageViews[item] {
                imageView = existing
            } else {
                imageView = UIImageView()
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.image = cachedImage(item)
                imageView.isHidden = imageView.image == nil
                if imageView.image == nil {
                    loadTasks[item] = Task { [weak self, weak imageView] in
                        let image = await loadImage(item)
                        guard !Task.isCancelled, let image, let imageView else { return }
                        imageView.image = image
                        imageView.isHidden = false
                        self?.loadTasks[item] = nil
                    }
                }
                imageLayer.addSubview(imageView)
                imageViews[item] = imageView
            }
            imageView.frame = frame
            imageView.alpha = alpha
        }
        for (item, imageView) in imageViews where !visible.contains(item) {
            imageView.removeFromSuperview()
            imageViews[item] = nil
            loadTasks.removeValue(forKey: item)?.cancel()
        }
    }

    override func removeFromSuperview() {
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        super.removeFromSuperview()
    }
}
