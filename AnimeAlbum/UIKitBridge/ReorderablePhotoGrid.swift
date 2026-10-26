import SwiftUI
import UIKit

/// 照片网格（DESIGN.md §6.1/§6.4）：图库与相簿详情共用，UICollectionView 桥接实现。
/// - 相簿：只有 UIKit 的 drag & drop 才能获得原生照片 App 同款的浮起/让位/自动滚屏排序手感；
/// - 图库：最初用 SwiftUI LazyVGrid，捏合换列时它边插值边按需创建/销毁格子、底部锚定又随内容高度
///   改偏移，动画抽搐；UICollectionView 的布局切换逐格插值，才顺滑（DESIGN.md §6.4 预留的降级路径）。
/// 同时支持捏合缩放列数（以手指下的格子为焦点）、Context Menu、点按回调，以及选择模式
/// （点选 + 滑动连选，选择期间关闭拖拽排序与 Context Menu）。
struct ReorderablePhotoGrid: UIViewRepresentable {
    let photos: [Photo]
    var onTap: (Int) -> Void
    var onMove: (UUID, Int) -> Void = { _, _ in }
    /// 长按菜单项（空数组则无菜单）；菜单自绘，见 PhotoContextMenu.swift
    var contextMenu: (UUID) -> [GridMenuItem] = { _ in [] }
    /// 供查看器查询单元当前全局 frame（自绘 zoom 过渡的起点/落点）
    var frameBox: GridFrameBox?
    /// 正在查看器中的照片：其单元渲染为空白，关闭动画结束后恢复
    var hiddenPhotoID: UUID?
    /// 选择模式：点按切换选中（不打开查看器），横向起手滑动连选
    var isSelecting = false
    var selectedIDs: Binding<Set<UUID>> = .constant([])
    /// 拖拽排序（相簿内）；图库按时间排序，不可拖
    var allowsReordering = true
    /// 进入时定位到最新（底部），停在底部时新增内容后仍保持在底部（图库）
    var anchorsToBottom = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PhotoGridContainerView {
        let coordinator = context.coordinator
        let collectionView = BottomAnchoredCollectionView(
            frame: .zero,
            collectionViewLayout: coordinator.makeLayout(zoomLevel: coordinator.zoomLevel))
        collectionView.anchorsToBottom = anchorsToBottom
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = coordinator
        // iPad 外接键盘：方向键在网格中移动焦点，回车 / 空格打开（走 didSelectItemAt，与点按同一路径）
        collectionView.allowsFocus = true
        // 长按：按下即逐渐浮起，0.3s 震动时已完全拿起、立即可拖（系统交互式移动），继续按住不动才弹出菜单。
        // 不用系统拖放与系统菜单：系统菜单的内部手势会压住这个长按（真机日志实测）；与系统拖放联动时
        // 又要「浮起后再等一下」才能拖 —— 都达不到「一震动就能拖」
        let reorder = PressLiftGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleReorderPress(_:)))
        reorder.minimumPressDuration = Coordinator.liftDuration
        reorder.delegate = coordinator
        reorder.onTouchDown = { [weak coordinator] location in coordinator?.pressDidTouchDown(at: location) }
        reorder.onReset = { [weak coordinator] in coordinator?.pressDidReset() }
        collectionView.addGestureRecognizer(reorder)
        coordinator.reorderRecognizer = reorder

        let pinch = UIPinchGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        collectionView.addGestureRecognizer(pinch)

        coordinator.configureDataSource(for: collectionView)
        coordinator.update(photos: photos)

        let swipe = coordinator.swipeSelection
        swipe.itemIndex = { [weak collectionView] point, exact in
            collectionView?.itemIndex(atWindowPoint: point, exact: exact)
        }
        swipe.onSelectionChange = { [weak coordinator] selection in
            coordinator?.parent.selectedIDs.wrappedValue = selection
            coordinator?.refreshVisibleSelection()
        }
        swipe.attach(to: collectionView)
        coordinator.updateSelectionMode()
        #if DEBUG
        // 调试辅助：AUTO_SWIPE=a-b（配合 ALBUM_SELECT）进入选择模式后模拟一次连选
        if let raw = ProcessInfo.processInfo.environment["AUTO_SWIPE"] {
            let bounds = raw.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2 {
                swipe.debugSimulate(from: bounds[0], to: bounds[1], after: .seconds(2))
            }
        }
        // SCROLL_TOP=1：1s 后滚到顶部（顶部 + 进出选择模式的位移问题都在顶部才可见）
        if ProcessInfo.processInfo.environment["SCROLL_TOP"] == "1" {
            Task { @MainActor [weak collectionView] in
                try? await Task.sleep(for: .seconds(1))
                guard let collectionView else { return }
                collectionView.setContentOffset(
                    CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
            }
        }
        // AUTO_REORDER=a-b：2s 后用交互式移动把第 a 张挪到第 b 张的位置（验证重排 → 写回 sortIndex）
        if let raw = ProcessInfo.processInfo.environment["AUTO_REORDER"] {
            let bounds = raw.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2 {
                Task { @MainActor [weak collectionView] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let collectionView,
                          let target = collectionView.layoutAttributesForItem(at: IndexPath(item: bounds[1], section: 0))
                    else {
                        return
                    }
                    guard collectionView.beginInteractiveMovementForItem(at: IndexPath(item: bounds[0], section: 0)) else { return }
                    collectionView.updateInteractiveMovementTargetPosition(target.center)
                    try? await Task.sleep(for: .milliseconds(400))
                    collectionView.endInteractiveMovement()
                }
            }
        }
        // AUTO_HOLD=n：2s 后模拟长按第 n 张并按住不动（带 ±1pt 手指抖动），逐帧打印照片显示尺寸（验证浮起 → 等菜单 → 菜单预览连续放大）
        if let index = ProcessInfo.processInfo.environment["AUTO_HOLD"].flatMap(Int.init) {
            Task { @MainActor [weak coordinator] in
                try? await Task.sleep(for: .seconds(2))
                coordinator?.debugHold(index: index)
            }
        }
        // AUTO_ZOOM=in/out：1.5s 后以屏幕中心为焦点换一档；AUTO_ZOOM_HOLD=0.5 停在半途 1.5s 再退回
        if let direction = ProcessInfo.processInfo.environment["AUTO_ZOOM"] {
            let hold = ProcessInfo.processInfo.environment["AUTO_ZOOM_HOLD"].flatMap(Double.init).map { CGFloat($0) }
            Task { @MainActor [weak coordinator] in
                try? await Task.sleep(for: .seconds(1.5))
                coordinator?.debugZoom(in: direction == "in", holdAt: hold)
            }
        }
        #endif

        frameBox?.lookup = { [weak coordinator] photoID in
            coordinator?.frameOfCell(photoID: photoID)
        }
        // 未被导航栏/Home 指示条遮挡的可见区域（窗口坐标）：查看器过渡按它裁切
        frameBox?.visibleRect = { [weak collectionView] in
            guard let collectionView, collectionView.window != nil else { return nil }
            let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
            return collectionView.convert(visible, to: nil)
        }
        return PhotoGridContainerView(collectionView: collectionView)
    }

    func updateUIView(_ container: PhotoGridContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(photos: photos)
        context.coordinator.updateHiddenPhoto(hiddenPhotoID)
        context.coordinator.updateSelectionMode()
    }

    static func dismantleUIView(_ container: PhotoGridContainerView, coordinator: Coordinator) {
        coordinator.swipeSelection.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var parent: ReorderablePhotoGrid
        let swipeSelection = SwipeSelectionController()

        // 长按排序状态
        struct ReorderPress {
            let indexPath: IndexPath
            let start: CGPoint
            /// 格子中心相对手指的偏移：拖动时保持抓取位置不变
            let grabOffset: CGPoint
            var isMoving = false
        }

        weak var reorderRecognizer: UILongPressGestureRecognizer?
        var reorderPress: ReorderPress?
        /// 自绘菜单显示中（期间不响应长按）
        var contextMenuActive = false
        /// 按下后、震动前的「逐渐浮起」：延迟开始的动画任务与对应格子
        var preLiftWork: DispatchWorkItem?
        weak var preLiftCell: UICollectionViewCell?
        /// 震动后手指不动、到点弹出菜单的计时
        var menuWork: DispatchWorkItem?
        /// 按下即浮起的时长（= 长按识别时长，震动时正好完全拿起）、震动后不动多久弹菜单
        static let liftDuration: TimeInterval = 0.3
        static let menuDelayAfterLift: TimeInterval = 0.45
        var reorderAutoScrollLink: CADisplayLink?
        var reorderAutoScrollVelocity: CGFloat = 0
        /// 捏合档位（由密到疏）：一行 15 张（原生相册最密档，固定列数）→ 按目标格子尺寸自适应的三档
        /// → 一行一张、按原始比例（不裁成正方形）
        private enum Density {
            case columns(Int)
            case cellTarget(CGFloat)
            case aspectList
        }

        private static let densities: [Density] = [
            .columns(15), .cellTarget(76), .cellTarget(110), .cellTarget(168), .aspectList,
        ]
        /// 照片宽高比（宽 / 高），按网格顺序：一行一张的布局按它排
        private var aspectRatios: [CGFloat] = []
        private static let defaultZoomLevel = 2

        var zoomLevel = defaultZoomLevel
        /// 当前格子使用的缩略图尺寸：最密档用 tiny，其余 small（换档开始时就切，退回时切回）
        private var thumbnailKind = thumbnailKind(forLevel: defaultZoomLevel)

        private static func thumbnailKind(forLevel level: Int) -> ThumbnailKind {
            switch densities[level] {
            case .columns(let count) where count >= 10:
                return .tiny
            case .aspectList:
                // 铺满屏宽（3x 屏上 ~1200px），small 的短边不够；large 每张导入时都已生成
                return .large
            default:
                return .small
            }
        }

        /// 切换格子缩略图尺寸并重配可见格子（新出现的格子由 cell registration 按新尺寸配置）
        private func applyThumbnailKind(forLevel level: Int) {
            let kind = Self.thumbnailKind(forLevel: level)
            guard kind != thumbnailKind else { return }
            thumbnailKind = kind
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath) as? PhotoCollectionCell,
                      let photoID = dataSource.itemIdentifier(for: indexPath)
                else {
                    continue
                }
                cell.configure(photoID: photoID, kind: kind)
            }
        }

        private var dataSource: ReorderableDataSource!
        private weak var collectionView: UICollectionView?

        init(_ parent: ReorderablePhotoGrid) {
            self.parent = parent
            super.init()
            #if DEBUG
            // 调试辅助：ZOOM_LEVEL=n 以指定档位启动（0 = 一行 15 张）
            if let raw = ProcessInfo.processInfo.environment["ZOOM_LEVEL"], let level = Int(raw),
               Self.densities.indices.contains(level) {
                zoomLevel = level
                thumbnailKind = Self.thumbnailKind(forLevel: level)
            }
            #endif
        }

        // MARK: 布局

        func makeLayout(zoomLevel: Int) -> any TargetOffsetOverriding {
            switch Self.densities[max(0, min(zoomLevel, Self.densities.count - 1))] {
            case .columns(let count):
                return PhotoGridLayout.make(columns: count, footerHeight: 64)
            case .cellTarget(let target):
                return PhotoGridLayout.make(cellTarget: target, footerHeight: 64)
            case .aspectList:
                let layout = PhotoAspectListLayout()
                layout.aspectRatios = aspectRatios
                return layout
            }
        }

        func configureDataSource(for collectionView: UICollectionView) {
            self.collectionView = collectionView

            let cellRegistration = UICollectionView.CellRegistration<PhotoCollectionCell, UUID> {
                [weak self] cell, _, photoID in
                cell.configure(photoID: photoID, kind: self?.thumbnailKind ?? .small)
                cell.setDocumentPageCount(self?.documentPageCounts[photoID])
                cell.setChecked(self?.isChecked(photoID) ?? false, animated: false)
                cell.isHidden = photoID == self?.hiddenPhotoID
            }
            dataSource = ReorderableDataSource(collectionView: collectionView) {
                collectionView, indexPath, photoID in
                collectionView.dequeueConfiguredReusableCell(
                    using: cellRegistration, for: indexPath, item: photoID)
            }

            // 交互式移动落定：数据源子类就地改快照（系统已把格子挪好，同序快照不再动画），只写一条 sortIndex。
            // 注意 reorderingHandlers 只对系统拖放生效，交互式移动不会回调它（实测）
            dataSource.canMoveItem = { [weak self] in self?.parent.allowsReordering ?? false }
            dataSource.didMoveItem = { [weak self] photoID, destination in
                self?.parent.onMove(photoID, destination)
            }

            let footerRegistration = UICollectionView.SupplementaryRegistration<GridFooterView>(
                elementKind: UICollectionView.elementKindSectionFooter
            ) { [weak self] footer, _, _ in
                footer.label.text = self?.footerText
            }
            dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
                collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
            }
        }

        /// PDF 的页数（格子左下角标记用）
        private var documentPageCounts: [UUID: Int] = [:]

        func update(photos: [Photo]) {
            documentPageCounts = Dictionary(
                photos.lazy.filter(\.isPDF).map { ($0.id, $0.pageCount) }, uniquingKeysWith: { first, _ in first })
            aspectRatios = photos.map { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : 1 }
            if let aspectLayout = collectionView?.collectionViewLayout as? PhotoAspectListLayout,
               aspectLayout.aspectRatios != aspectRatios {
                aspectLayout.aspectRatios = aspectRatios
            }
            let ids = photos.map(\.id)
            guard ids != dataSource.snapshot().itemIdentifiers else { return }

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            // 停在底部时新增照片（导入）后仍贴住底部，新照片直接可见（原生同款）
            let anchored = collectionView as? BottomAnchoredCollectionView
            let sticksToBottom = parent.anchorsToBottom && (anchored?.isAtBottom ?? false)
            dataSource.apply(snapshot, animatingDifferences: true) {
                if sticksToBottom {
                    anchored?.scrollToBottom(animated: true)
                }
            }
            // 页脚只在创建时配置一次，数量变了要手动刷新（否则导入 / 删除后计数不变）
            for footer in collectionView?.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter) ?? [] {
                (footer as? GridFooterView)?.label.text = footerText
            }
        }

        /// 「N 张照片、M 个 PDF」
        private var footerText: String {
            let total = dataSource.snapshot().numberOfItems
            let documents = documentPageCounts.count
            let images = total - documents
            switch (images, documents) {
            case (_, 0): return "\(images) 张照片"
            case (0, _): return "\(documents) 个 PDF"
            default: return "\(images) 张照片、\(documents) 个 PDF"
            }
        }

        private var hiddenPhotoID: UUID?

        func updateHiddenPhoto(_ id: UUID?) {
            guard id != hiddenPhotoID else { return }
            hiddenPhotoID = id
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath),
                      let cellID = dataSource.itemIdentifier(for: indexPath)
                else {
                    continue
                }
                cell.isHidden = cellID == id
            }
        }

        // MARK: 选择模式

        private func isChecked(_ photoID: UUID) -> Bool {
            parent.isSelecting && parent.selectedIDs.wrappedValue.contains(photoID)
        }

        /// 同步选择模式：选择期间关闭拖拽排序（长按留给系统、横滑留给连选），刷新勾选态
        func updateSelectionMode() {
            reorderRecognizer?.isEnabled = !parent.isSelecting
            swipeSelection.isEnabled = parent.isSelecting
            swipeSelection.itemIDs = dataSource.snapshot().itemIdentifiers
            swipeSelection.selection = parent.selectedIDs.wrappedValue
            refreshVisibleSelection()
        }

        func refreshVisibleSelection() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath) as? PhotoCollectionCell,
                      let photoID = dataSource.itemIdentifier(for: indexPath)
                else {
                    continue
                }
                cell.setChecked(isChecked(photoID), animated: true)
            }
        }

        // MARK: 捏合缩放列数（交互式）

        /// 一次进行中的换档：跟手推进、可停在中途、可退回（原生同款）。
        ///
        /// 正方形网格之间：方块网格随进度缩放，每个方块里旧照片淡出、新照片淡入，照片不移动
        /// （PhotoGridZoomTransitionLayout）；网格 ↔ 一行一张：焦点照片变形、其余两层缩放 + 整层淡出
        /// （PhotoGridMorphTransitionLayout）。旧照片都画在 PinchCrossfadeOverlay 上
        private struct PinchTransition {
            let layout: UICollectionViewTransitionLayout
            let overlay: PinchCrossfadeOverlay
            let targetLevel: Int
            let previousOffsetY: CGFloat
            let nextOffsetY: CGFloat
            /// 新 / 旧格子边长比：捏合比例到达它时进度为 1
            let sizeRatio: CGFloat
            var progress: CGFloat = 0
            /// 已在收尾（松手后的动画 / 已提交），不再接受手势推进
            var isSettling = false
        }

        private var pinchTransition: PinchTransition?
        /// 网格 ↔ 一行一张时焦点照片用的图（先用已缓存的，大图加载好后替换）
        private var focusImage: UIImage?
        /// 旧照片层取图：序号 → 旧档位照片的已缓存缩略图 / 未缓存时异步加载
        private var previousItemImage: (Int) -> UIImage? = { _ in nil }
        private var loadPreviousItemImage: @Sendable (Int) async -> UIImage? = { _ in nil }

        /// 当前这一档开始时的捏合比例（一档走满后继续捏，以此为新起点进入下一档）
        private var pinchBaseScale: CGFloat = 1
        /// 同一次捏合里一档走满后继续换档的方向（true = 放大）；nil 表示这是本次捏合的第一档。
        /// 连续换档时：不设死区、不加起步阻尼、沿用画面速度、多捏的行程直接计入下一档 ——
        /// 否则每档之间都会顿一下（实测）
        private var pinchContinuation: Bool?

        /// 跟手限速：画面进度不直接等于手指位置，而是平滑追赶手指（响应 0.1s）且速度封顶 ——
        /// 手指慢时几乎贴手，手指快时画面匀速追上，完成一档最快 ~0.22s（不封顶时手快就快得突兀；
        /// 2、3 档/秒又嫌慢，实测）。
        /// 松手时收尾从画面当前速度（≤ 上限）接着走，不会出现「松手瞬间速度被砍」的急刹
        private static let followMaxSpeed: CGFloat = 4.5
        private static let followResponse: CGFloat = 0.06
        private var followLink: CADisplayLink?
        private var followTarget: CGFloat = 0
        private var followVelocity: CGFloat = 0
        private var lastFollowTimestamp: CFTimeInterval?

        private var settleLink: CADisplayLink?

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                pinchBaseScale = recognizer.scale
                pinchContinuation = nil
            case .changed:
                if pinchTransition?.isSettling == true { return }
                let relative = recognizer.scale / pinchBaseScale
                if pinchTransition == nil, let anchor = collectionView.map({ recognizer.location(in: $0.superview) }) {
                    // 第一档用小死区判方向（捏开 = 放大 / 更少列，捏合 = 缩小 / 更多列）；
                    // 连续换档同方向不设死区，立刻接上
                    let zoomInThreshold: CGFloat = pinchContinuation == true ? 1 : 1.02
                    let zoomOutThreshold: CGFloat = pinchContinuation == false ? 1 : 0.98
                    if relative > zoomInThreshold, zoomLevel < Self.densities.count - 1 {
                        if pinchContinuation == false { pinchContinuation = nil }
                        beginPinchTransition(toLevel: zoomLevel + 1, anchor: anchor)
                    } else if relative < zoomOutThreshold, zoomLevel > 0 {
                        if pinchContinuation == true { pinchContinuation = nil }
                        beginPinchTransition(toLevel: zoomLevel - 1, anchor: anchor)
                    }
                }
                guard let transition = pinchTransition else { return }
                // 手指行程 = 捏合比例走过「新旧边长比」的比例（反向捏回起点以下即为 0，退回原样）；
                // 第一档的画面进度再经阻尼曲线（起步慢、越往后越跟手），连续换档直接线性
                let travel = min(max((relative - 1) / (transition.sizeRatio - 1), 0), 1)
                followTarget = pinchContinuation == nil ? Self.pinchCurve(travel) : travel
                startFollow()
            case .ended, .cancelled, .failed:
                stopFollow()
                guard pinchTransition?.isSettling == false else { return }
                // 完成还是退回看手指的意图：手指位置（阻尼曲线后）+ 手指速度投射；
                // 收尾动画则从画面当前进度与速度接着走
                let travel = min(max((recognizer.scale / pinchBaseScale - 1) / (pinchTransition!.sizeRatio - 1), 0), 1)
                let fingerVelocity = recognizer.velocity / pinchBaseScale / (pinchTransition!.sizeRatio - 1)
                    * (pinchContinuation == nil ? Self.pinchCurveSlope(travel) : 1)
                let projected = followTarget + fingerVelocity * 0.15
                settlePinch(to: projected > 0.5 ? 1 : 0, velocity: followVelocity)
            default:
                break
            }
        }

        /// 起步阻尼：手指行程 u → 画面进度 f(u) = (1−k)·u² + k·u。起点斜率 k（手指走 1 份画面只走 k 份），
        /// 终点斜率 2 − k；f(0)=0、f(1)=1，完成一档所需的捏合幅度不变。
        /// k = 1 即无阻尼；0.35 实测阻尼过大、起步发黏
        private static let pinchStartDamping: CGFloat = 0.6

        private static func pinchCurve(_ travel: CGFloat) -> CGFloat {
            (1 - pinchStartDamping) * travel * travel + pinchStartDamping * travel
        }

        private static func pinchCurveSlope(_ travel: CGFloat) -> CGFloat {
            2 * (1 - pinchStartDamping) * travel + pinchStartDamping
        }

        private func beginPinchTransition(toLevel level: Int, anchor: CGPoint) {
            guard let collectionView, let container = collectionView.superview,
                  settleLink == nil, pinchTransition == nil
            else {
                return
            }
            let previousLayout = collectionView.collectionViewLayout
            let previousOffsetY = collectionView.contentOffset.y

            // 焦点格子：手指下（或最近）的那张；它所在的行在换档中保持在视口里的同一高度
            guard let focusItem = collectionView.itemIndex(atWindowPoint: container.convert(anchor, to: nil), exact: false),
                  let fromFrame = previousLayout.layoutAttributesForItem(at: IndexPath(item: focusItem, section: 0))?.frame
            else {
                return
            }
            let focusIndexPath = IndexPath(item: focusItem, section: 0)

            let newLayout = makeLayout(zoomLevel: level)
            let previousKind = thumbnailKind
            // 过渡中新出现的格子按目标档位的缩略图尺寸配置
            thumbnailKind = Self.thumbnailKind(forLevel: level)
            let transitionLayout = collectionView.startInteractiveTransition(to: newLayout) { [weak self] _, finished in
                self?.pinchTransitionDidEnd(finished: finished)
            }
            guard let toFrame = newLayout.layoutAttributesForItem(at: focusIndexPath)?.frame,
                  fromFrame.width > 0, abs(toFrame.width - fromFrame.width) > 0.5
            else {
                // 两档同列数（极窄容器）：无可缩放，直接落定
                thumbnailKind = previousKind
                zoomLevel = level
                applyThumbnailKind(forLevel: level)
                collectionView.finishInteractiveTransition()
                return
            }

            let insets = collectionView.adjustedContentInset
            let minY = -insets.top
            let maxY = max(minY, newLayout.collectionViewContentSize.height + insets.bottom - collectionView.bounds.height)
            let viewport = CGRect(origin: .zero, size: collectionView.bounds.size)
            let fingerY = anchor.y - collectionView.frame.minY
            let nextOffsetY: CGFloat
            let overlay: PinchCrossfadeOverlay
            if let zoomLayout = transitionLayout as? PhotoGridZoomTransitionLayout {
                // 新布局的滚动位置：以手指高度为中心缩放到终点时，焦点格子中心会落在
                // 手指 + 比例 ×（中心 − 手指）的高度；让新布局里它停在那里（夹在可滚动范围内）
                let anchorY = fromFrame.midY - previousOffsetY
                let landingY = fingerY + (anchorY - fingerY) * (toFrame.width / fromFrame.width)
                nextOffsetY = min(max(toFrame.midY - landingY, minY), maxY)
                let width = collectionView.bounds.width
                let spacing = PhotoGridLayout.spacing
                zoomLayout.geometry = PhotoGridZoomTransitionLayout.Geometry(
                    fromOffsetY: previousOffsetY,
                    toOffsetY: nextOffsetY,
                    fromAnchorY: anchorY,
                    toAnchorY: toFrame.midY - nextOffsetY,
                    fromCellSize: fromFrame.width,
                    toCellSize: toFrame.width,
                    fromColumns: max(1, Int(((width + spacing) / (fromFrame.width + spacing)).rounded())),
                    toColumns: max(1, Int(((width + spacing) / (toFrame.width + spacing)).rounded())),
                    focusItem: focusItem,
                    itemCount: collectionView.numberOfItems(inSection: 0),
                    viewport: viewport,
                    finger: CGPoint(x: anchor.x - collectionView.frame.minX, y: fingerY))
                // 旧照片层：盖在网格上、与网格方块逐个重合，逐格淡化（进度 0 时与换档前画面完全一致）
                overlay = PinchCrossfadeOverlay(frame: collectionView.frame)
            } else if let morphLayout = transitionLayout as? PhotoGridMorphTransitionLayout {
                // 网格 ↔ 一行一张：焦点照片中心保持在原来的视口高度（夹在可滚动范围内）
                let fromFocus = fromFrame.offsetBy(dx: 0, dy: -previousOffsetY)
                nextOffsetY = min(max(toFrame.midY - fromFocus.midY, minY), maxY)
                morphLayout.geometry = PhotoGridMorphTransitionLayout.Geometry(
                    fromOffsetY: previousOffsetY,
                    toOffsetY: nextOffsetY,
                    focusItem: focusItem,
                    fromFocus: fromFocus,
                    toFocus: toFrame.offsetBy(dx: 0, dy: -nextOffsetY),
                    viewport: viewport)
                // 旧布局一层带不透明底、整层淡出；进度 0 时完全盖住底下缩小着的新布局
                overlay = PinchCrossfadeOverlay(frame: collectionView.frame, opaqueBackground: true)
            } else {
                thumbnailKind = previousKind
                collectionView.cancelInteractiveTransition()
                return
            }
            // 落定 / 退回时系统会向新 / 旧布局要目标偏移：都给出我们算好的值，交接那一帧不跳
            newLayout.targetOffsetOverride = CGPoint(x: 0, y: nextOffsetY)
            (previousLayout as? TargetOffsetOverriding)?.targetOffsetOverride = CGPoint(x: 0, y: previousOffsetY)
            container.insertSubview(overlay, aboveSubview: collectionView)

            // 换档期间不滚动：滚动偏移由进度驱动
            collectionView.panGestureRecognizer.isEnabled = false
            followTarget = 0
            if pinchContinuation == nil {
                followVelocity = 0
            }
            let itemIDs = dataSource.snapshot().itemIdentifiers
            previousItemImage = { item in
                guard itemIDs.indices.contains(item) else { return nil }
                let id = itemIDs[item]
                return ThumbnailCache.shared.cachedImage(for: id, kind: previousKind)
                    ?? [ThumbnailKind.small, .tiny].lazy.compactMap { ThumbnailCache.shared.cachedImage(for: id, kind: $0) }.first
            }
            loadPreviousItemImage = { item in
                guard itemIDs.indices.contains(item) else { return nil }
                return await ThumbnailCache.shared.image(for: itemIDs[item], kind: previousKind)
            }
            // 预热：新布局在终点时可见的照片先进内存缓存，交叉淡化开始时新格子已有图（未加载的格子是浅灰占位，
            // 淡化时看起来就是发白）
            let newKind = Self.thumbnailKind(forLevel: level)
            let visibleAtEnd = newLayout.layoutAttributesForElements(
                in: CGRect(x: 0, y: nextOffsetY, width: collectionView.bounds.width, height: collectionView.bounds.height)) ?? []
            for attributes in visibleAtEnd where attributes.representedElementCategory == .cell {
                guard itemIDs.indices.contains(attributes.indexPath.item) else { continue }
                let id = itemIDs[attributes.indexPath.item]
                if ThumbnailCache.shared.cachedImage(for: id, kind: newKind) == nil {
                    Task { _ = await ThumbnailCache.shared.image(for: id, kind: newKind) }
                }
            }
            let focusID = itemIDs.indices.contains(focusItem) ? itemIDs[focusItem] : nil
            focusImage = focusID.flatMap { id in
                [ThumbnailKind.large, .small, .tiny].lazy.compactMap { ThumbnailCache.shared.cachedImage(for: id, kind: $0) }.first
            }
            if let focusID, transitionLayout is PhotoGridMorphTransitionLayout,
               ThumbnailCache.shared.cachedImage(for: focusID, kind: .large) == nil {
                // 焦点照片要放大到铺满屏宽：先用手头的缩略图，大图到了再换上
                Task { [weak self] in
                    let image = await ThumbnailCache.shared.image(for: focusID, kind: .large)
                    guard let self, let image, self.pinchTransition != nil else { return }
                    self.focusImage = image
                }
            }
            pinchTransition = PinchTransition(
                layout: transitionLayout,
                overlay: overlay,
                targetLevel: level,
                previousOffsetY: previousOffsetY,
                nextOffsetY: nextOffsetY,
                sizeRatio: toFrame.width / fromFrame.width)
            // 仍在屏上的复用格子按新档位的缩略图尺寸重配
            thumbnailKind = previousKind
            applyThumbnailKind(forLevel: level)
            setPinchProgress(0)
        }

        private func startFollow() {
            guard followLink == nil else { return }
            lastFollowTimestamp = nil
            let link = CADisplayLink(target: self, selector: #selector(followTick(_:)))
            link.add(to: .main, forMode: .common)
            followLink = link
        }

        private func stopFollow() {
            followLink?.invalidate()
            followLink = nil
            lastFollowTimestamp = nil
        }

        /// 画面进度追赶手指：临界阻尼跟随 + 速度封顶；追到走满一档时就地落定，继续捏进入下一档
        @objc private func followTick(_ link: CADisplayLink) {
            guard let transition = pinchTransition, !transition.isSettling else {
                stopFollow()
                return
            }
            defer { lastFollowTimestamp = link.timestamp }
            guard let last = lastFollowTimestamp else { return }

            let omega = 2 * CGFloat.pi / Self.followResponse
            var x = transition.progress
            var v = followVelocity
            var remaining = CGFloat(min(link.timestamp - last, 1.0 / 30))
            while remaining > 0 {
                let dt = min(remaining, 1.0 / 240)
                v += (-omega * omega * (x - followTarget) - 2 * omega * v) * dt
                v = min(max(v, -Self.followMaxSpeed), Self.followMaxSpeed)
                x += v * dt
                if x <= 0 || x >= 1 {
                    x = min(max(x, 0), 1)
                    v = 0
                }
                remaining -= dt
            }
            followVelocity = v
            setPinchProgress(x)

            if followTarget >= 1, x >= 0.999 {
                // 一档走满：就地落定（已在终点、无跳变）。下一档的起点取「行程到 1 时的捏合比例」，
                // 多捏的部分直接计入；画面速度保留（换算到新一档的进度单位 ≈ 不变）
                stopFollow()
                setPinchProgress(1)
                pinchBaseScale *= transition.sizeRatio
                pinchContinuation = transition.sizeRatio > 1
                endPinchTransition(committed: true)
            }
        }

        /// 推进进度：过渡布局按进度给出每格的位置 / 尺寸 / 透明度，滚动偏移在两档的目标偏移间同步插值
        private func setPinchProgress(_ progress: CGFloat) {
            guard let collectionView, var transition = pinchTransition else { return }
            transition.progress = progress
            pinchTransition = transition
            // 先推进度再设偏移：过渡中系统会按过渡布局的 targetContentOffset 改写偏移，它要按新进度算
            transition.layout.transitionProgress = progress
            collectionView.contentOffset.y = transition.previousOffsetY
                + (transition.nextOffsetY - transition.previousOffsetY) * progress
            transition.layout.invalidateLayout()
            if let zoomLayout = transition.layout as? PhotoGridZoomTransitionLayout {
                // 旧照片层：方块位置与逐格透明度随进度更新（规则见 PhotoGridZoomTransitionLayout）
                transition.overlay.update(
                    items: zoomLayout.previousItems(), cachedImage: previousItemImage, loadImage: loadPreviousItemImage)
            } else if let morphLayout = transition.layout as? PhotoGridMorphTransitionLayout {
                // 旧布局一层随缩放更新、整层淡出；焦点照片单独变形、不淡化
                transition.overlay.update(
                    items: morphLayout.previousItems(), cachedImage: previousItemImage, loadImage: loadPreviousItemImage)
                transition.overlay.layerAlpha = 1 - PhotoGridZoomTransitionLayout.crossfade(progress)
                transition.overlay.setFocus(frame: morphLayout.focusFrame(), image: focusImage)
            }
        }

        /// 收尾：进度已在终点（1 = 完成、0 = 退回），交给系统落定布局；滚动偏移在落定后再校准一次
        private func endPinchTransition(committed: Bool) {
            guard let collectionView, pinchTransition != nil else { return }
            pinchTransition?.isSettling = true
            if committed {
                collectionView.finishInteractiveTransition()
            } else {
                applyThumbnailKind(forLevel: zoomLevel)
                collectionView.cancelInteractiveTransition()
            }
        }

        private func pinchTransitionDidEnd(finished: Bool) {
            guard let collectionView, let transition = pinchTransition else { return }
            transition.overlay.removeFromSuperview()
            previousItemImage = { _ in nil }
            loadPreviousItemImage = { _ in nil }
            // 覆盖值只服务于这次交接，之后恢复默认（不影响旋转等其它布局更新）
            (transition.layout.currentLayout as? TargetOffsetOverriding)?.targetOffsetOverride = nil
            (transition.layout.nextLayout as? TargetOffsetOverriding)?.targetOffsetOverride = nil
            focusImage = nil
            if finished {
                zoomLevel = transition.targetLevel
            }
            collectionView.contentOffset.y = finished ? transition.nextOffsetY : transition.previousOffsetY
            collectionView.panGestureRecognizer.isEnabled = true
            pinchTransition = nil
        }

        /// 收尾时长：按剩余距离 0.25～0.45s（整档走完最慢）。实测 0.45～0.8s、0.35～0.6s 都嫌慢；
        /// 早先 0.3～0.55s 嫌快是因为手快时还会再缩短时长、且没有跟手限速
        private static let settleBaseDuration: CFTimeInterval = 0.25
        private static let settleDistanceDuration: CFTimeInterval = 0.2

        private struct SettleCurve {
            /// 已走过的时间：逐帧累积且每帧最多 1/30s —— 主线程卡顿时动画停一下，而不是按墙钟
            /// 直接跳到后段（实测进出 15 列档时开头一卡，整段过渡被跳过）
            var elapsed: CFTimeInterval = 0
            var lastTimestamp: CFTimeInterval?
            let from: CGFloat
            let to: CGFloat
            let velocity: CGFloat
            let duration: CGFloat
            /// 速度大时改用减速幂曲线（指数 n = v·T / 距离）
            let decayExponent: CGFloat?

            func value() -> (progress: CGFloat, finished: Bool) {
                let t = min(CGFloat(elapsed) / duration, 1)
                guard t < 1 else { return (to, true) }
                if let n = decayExponent {
                    // x = 终点 − 距离·(1−t)^n：起速 n·距离/T = 手指速度，之后像惯性滚动一样逐渐减速，单调不越界
                    return (to - (to - from) * pow(1 - t, n), false)
                }
                // 三次 Hermite：起速 = 手指速度、终速 0；v·T ≤ 3·距离 时单调
                let t2 = t * t
                let t3 = t2 * t
                let h00 = 2 * t3 - 3 * t2 + 1
                let h10 = t3 - 2 * t2 + t
                let h01 = -2 * t3 + 3 * t2
                return (h00 * from + h10 * duration * velocity + h01 * to, false)
            }
        }

        private var settleCurve: SettleCurve?

        /// 松手后的收尾：起点速度 = 手指的捏合速度（无衔接突变、不封顶），终点速度 0（平滑停住），
        /// 全程单调、绝不冲过终点；时长固定按距离给（不因手快而缩短 —— 实测会快得突兀）。
        /// 手快到三次曲线会越界（v·T > 3·距离）时改用减速幂曲线，仍接住速度、仍是这个时长。
        /// 不用弹簧：初速度大时会冲过终点，而进度被夹在 0～1，冲出去的那段在画面上就是撞到终点急停；
        /// 给速度封顶又会在松手瞬间突然变慢 —— 两者都是肉眼可见的跳变（实测）
        private func settlePinch(to target: CGFloat, velocity: CGFloat) {
            guard let transition = pinchTransition else { return }
            pinchTransition?.isSettling = true
            let distance = target - transition.progress
            var duration = CGFloat(Self.settleBaseDuration + Self.settleDistanceDuration * Double(abs(distance)))
            if UIAccessibility.isReduceMotionEnabled {
                duration *= 0.6
            }
            let exponent = distance != 0 ? velocity * duration / distance : 0
            settleCurve = SettleCurve(
                from: transition.progress,
                to: target,
                velocity: velocity,
                duration: duration,
                decayExponent: exponent > 3 ? exponent : nil)
            let link = CADisplayLink(target: self, selector: #selector(settleTick(_:)))
            link.add(to: .main, forMode: .common)
            settleLink = link
        }

        @objc private func settleTick(_ link: CADisplayLink) {
            guard pinchTransition != nil, var curve = settleCurve else {
                stopSettle()
                return
            }
            if let last = curve.lastTimestamp {
                curve.elapsed += min(link.targetTimestamp - last, 1.0 / 30)
            }
            curve.lastTimestamp = link.targetTimestamp
            settleCurve = curve
            let (value, finished) = curve.value()
            setPinchProgress(finished ? curve.to : min(max(value, 0), 1))
            guard finished else { return }
            stopSettle()
            endPinchTransition(committed: curve.to >= 1)
        }

        private func stopSettle() {
            settleLink?.invalidate()
            settleLink = nil
            settleCurve = nil
        }

        #if DEBUG
        /// AUTO_ZOOM 调试：以屏幕中心为焦点走同一套交互式换档。holdAt 给定时停在该进度 1.5s 再退回
        func debugZoom(in zoomingIn: Bool, holdAt progress: CGFloat?) {
            guard let collectionView, let container = collectionView.superview,
                  collectionView.window != nil, pinchTransition == nil
            else {
                return
            }
            let level = zoomLevel + (zoomingIn ? 1 : -1)
            guard Self.densities.indices.contains(level) else { return }
            beginPinchTransition(toLevel: level, anchor: CGPoint(x: container.bounds.midX, y: container.bounds.midY))
            guard pinchTransition != nil else { return }
            if let progress {
                setPinchProgress(progress)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.settlePinch(to: 0, velocity: 0)
                }
            } else {
                settlePinch(to: 1, velocity: 0)
            }
        }
        #endif

        private func photoID(at indexPath: IndexPath) -> UUID? {
            dataSource.itemIdentifier(for: indexPath)
        }

        /// 单元当前的全局（窗口坐标系）frame；不可见返回 nil
        func frameOfCell(photoID: UUID) -> CGRect? {
            guard let collectionView,
                  let indexPath = dataSource.indexPath(for: photoID),
                  let cell = collectionView.cellForItem(at: indexPath)
            else {
                return nil
            }
            return cell.convert(cell.bounds, to: nil)
        }
    }
}

// MARK: - UICollectionViewDelegate

extension ReorderablePhotoGrid.Coordinator: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        transitionLayoutForOldLayout fromLayout: UICollectionViewLayout,
        newLayout toLayout: UICollectionViewLayout
    ) -> UICollectionViewTransitionLayout {
        // 两边都是正方形网格：方块缩放 + 原地淡化；涉及一行一张（格子形状不同）：焦点变形 + 两层淡化
        if fromLayout is PhotoGridCompositionalLayout, toLayout is PhotoGridCompositionalLayout {
            return PhotoGridZoomTransitionLayout(currentLayout: fromLayout, nextLayout: toLayout)
        }
        return PhotoGridMorphTransitionLayout(currentLayout: fromLayout, nextLayout: toLayout)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard parent.isSelecting else {
            parent.onTap(indexPath.item)
            return
        }
        guard let photoID = dataSource.itemIdentifier(for: indexPath) else { return }
        if parent.selectedIDs.wrappedValue.contains(photoID) {
            parent.selectedIDs.wrappedValue.remove(photoID)
        } else {
            parent.selectedIDs.wrappedValue.insert(photoID)
        }
        refreshVisibleSelection()
    }
}

// MARK: - 长按排序（按一下即可拖，手指不动才进菜单）

/// 支持交互式移动的数据源：系统落定移动时回调 moveItemAt，这里同步快照并上报
final class ReorderableDataSource: UICollectionViewDiffableDataSource<Int, UUID> {
    var canMoveItem: () -> Bool = { false }
    var didMoveItem: (UUID, Int) -> Void = { _, _ in }

    override func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        canMoveItem()
    }

    override func collectionView(
        _ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath
    ) {
        var snapshot = snapshot()
        let ids = snapshot.itemIdentifiers
        guard ids.indices.contains(sourceIndexPath.item), ids.indices.contains(destinationIndexPath.item),
              sourceIndexPath != destinationIndexPath
        else {
            return
        }
        let moved = ids[sourceIndexPath.item]
        let anchor = ids[destinationIndexPath.item]
        snapshot.deleteItems([moved])
        if destinationIndexPath.item > sourceIndexPath.item {
            snapshot.insertItems([moved], afterItem: anchor)
        } else {
            snapshot.insertItems([moved], beforeItem: anchor)
        }
        apply(snapshot, animatingDifferences: false)
        didMoveItem(moved, destinationIndexPath.item)
    }
}

extension ReorderablePhotoGrid.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === reorderRecognizer, let collectionView else { return true }
        guard !parent.isSelecting, !contextMenuActive, pinchTransition == nil,
              let indexPath = collectionView.indexPathForItem(at: gestureRecognizer.location(in: collectionView))
        else {
            return false
        }
        return canReorder || hasMenu(at: indexPath)
    }

    /// 不与滚动并存：进入长按后手指移动是拖动不是滚动
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === reorderRecognizer && otherGestureRecognizer !== collectionView?.panGestureRecognizer
    }
}

extension ReorderablePhotoGrid.Coordinator {
    /// 一行一张（格子高度各异）不支持排序：移动中布局按原顺序的宽高比排，会错乱
    var canReorder: Bool {
        parent.allowsReordering && !(collectionView?.collectionViewLayout is PhotoAspectListLayout)
    }

    func hasMenu(at indexPath: IndexPath) -> Bool {
        guard let photoID = dataSource.itemIdentifier(for: indexPath) else { return false }
        return !parent.contextMenu(photoID).isEmpty
    }

    // MARK: 按下 → 逐渐浮起（震动前就有被拿起的迹象）

    func pressDidTouchDown(at location: CGPoint) {
        guard let collectionView, !parent.isSelecting, !contextMenuActive, pinchTransition == nil,
              let indexPath = collectionView.indexPathForItem(at: location),
              let cell = collectionView.cellForItem(at: indexPath),
              canReorder || hasMenu(at: indexPath)
        else {
            return
        }
        preLiftWork?.cancel()
        // 能排序又有菜单（相簿）：震动后还要按住等菜单 —— 浮起与按住放大接成一条曲线，震动处不停顿
        let continuesToHold = canReorder && hasMenu(at: indexPath)
        // 稍等一下再开始（快速轻点只是打开照片，不该闪一下），在长按识别的那一刻正好完全拿起 ——
        // 时长按「按下时刻 + 识别时长」现算：延迟任务常晚到一帧，固定时长会在震动时还没浮起完、被进入拖动直接设成 1.1 倍而跳一下
        let recognizeTime = CACurrentMediaTime() + Self.liftDuration
        let work = DispatchWorkItem { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.preLiftCell = cell
            let liftDuration = max(recognizeTime - CACurrentMediaTime(), 0.05)
            guard continuesToHold, let photoCell = cell as? PhotoCollectionCell else {
                self.setLifted(true, cell: cell, duration: liftDuration)
                return
            }
            let curve = PressCurve(liftDuration: liftDuration)
            photoCell.setPressLifted(true, scale: curve.finalScale, duration: curve.totalDuration, timing: PressCurve.timing)
        }
        preLiftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 长按失败（轻点 / 滑动滚屏）或结束复位：没拿起的照片落回
    func pressDidReset() {
        preLiftWork?.cancel()
        preLiftWork = nil
        if reorderPress == nil, !contextMenuActive, let cell = preLiftCell {
            setLifted(false, cell: cell, duration: 0.2)
        }
        preLiftCell = nil
    }

    // MARK: 震动 → 立即可拖；不动 → 菜单

    @objc func handleReorderPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let collectionView else { return }
        let location = recognizer.location(in: collectionView)
        switch recognizer.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: reorderPressStartItem(recognizer) ?? location)
            else {
                return
            }
            beginPress(at: indexPath, location: location)
        case .changed:
            movePress(to: location)
        case .ended:
            endReorder(commit: true)
        default:
            endReorder(commit: false)
        }
    }

    /// 长按识别（震动）：能排序时立即进入拖动并开始等菜单，不能排序时直接弹菜单
    func beginPress(at indexPath: IndexPath, location: CGPoint) {
        guard let collectionView, let cell = collectionView.cellForItem(at: indexPath) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard canReorder else {
            // 图库（不能排序）：震动即弹菜单
            presentMenu(for: indexPath)
            return
        }
        var press = ReorderPress(indexPath: indexPath, start: location,
                                 grabOffset: CGPoint(x: cell.center.x - location.x, y: cell.center.y - location.y))
        // 一震动就进入拖动：此刻照片已完全浮起（与移动中的布局属性同为 1.1 倍 + 投影，交接无跳变）
        if collectionView.beginInteractiveMovementForItem(at: indexPath) {
            press.isMoving = true
            collectionView.updateInteractiveMovementTargetPosition(
                CGPoint(x: location.x + press.grabOffset.x, y: location.y + press.grabOffset.y))
        }
        reorderPress = press
        // 等菜单期间照片沿浮起时排好的曲线继续缓慢放大（PressCurve），菜单预览从那里接着放大
        scheduleMenu(for: indexPath)
    }

    func movePress(to location: CGPoint) {
        guard let collectionView, let press = reorderPress, press.isMoving else { return }
        if menuWork != nil, hypot(location.x - press.start.x, location.y - press.start.y) > 8 {
            // 手指动了：是拖动，不再弹菜单；照片退回拖动时的 1.1 倍
            menuWork?.cancel()
            menuWork = nil
            (preLiftCell as? PhotoCollectionCell)?.setPressScale(PhotoCollectionCell.liftedScale, duration: 0.2)
        }
        collectionView.updateInteractiveMovementTargetPosition(
            CGPoint(x: location.x + press.grabOffset.x, y: location.y + press.grabOffset.y))
        updateReorderAutoScroll(for: location)
    }

    /// 手势在 .began 时可能已漂移几个点：用按下时的格子
    private func reorderPressStartItem(_ recognizer: UILongPressGestureRecognizer) -> CGPoint? {
        guard let cell = preLiftCell, let collectionView else { return nil }
        return collectionView.convert(cell.center, from: cell.superview)
    }

    private func scheduleMenu(for indexPath: IndexPath) {
        menuWork?.cancel()
        guard hasMenu(at: indexPath) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let press = self.reorderPress else { return }
            // 震动后一直没动：放下拖动，弹出菜单
            self.stopReorderAutoScroll()
            if press.isMoving {
                self.collectionView?.cancelInteractiveMovement()
            }
            self.reorderPress = nil
            self.presentMenu(for: press.indexPath)
        }
        menuWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuDelayAfterLift, execute: work)
    }

    func endReorder(commit: Bool) {
        menuWork?.cancel()
        menuWork = nil
        stopReorderAutoScroll()
        if let press = reorderPress, press.isMoving {
            if commit {
                collectionView?.endInteractiveMovement()
            } else {
                collectionView?.cancelInteractiveMovement()
            }
        }
        reorderPress = nil
        if let cell = preLiftCell, !contextMenuActive {
            setLifted(false, cell: cell, duration: 0.2)
        }
        preLiftCell = nil
    }

    // MARK: 菜单

    private func presentMenu(for indexPath: IndexPath) {
        guard let collectionView, let window = collectionView.window,
              let photoID = dataSource.itemIdentifier(for: indexPath),
              let cell = collectionView.cellForItem(at: indexPath)
        else {
            return
        }
        let items = parent.contextMenu(photoID)
        guard !items.isEmpty else { return }
        contextMenuActive = true
        // 预览从浮起后的位置接着放大、收起时回到格子原位；菜单期间格子隐藏（照片「离开」了格子）
        let photoCell = cell as? PhotoCollectionCell
        let holding = photoCell?.displayedPressScale ?? 1
        let liftedFrame = cell.convert(cell.bounds, to: window)
        let startFrame = liftedFrame.insetBy(dx: liftedFrame.width * (1 - holding) / 2,
                                             dy: liftedFrame.height * (1 - holding) / 2)
        cell.layer.removeAllAnimations()
        setLifted(false, cell: cell, duration: 0)
        let sourceFrame = cell.convert(cell.bounds, to: window)
        photoCell?.isHiddenForMenu = true
        let placeholder = photoCell?.currentImage
        let aspectRatio = aspectRatios.indices.contains(indexPath.item) ? aspectRatios[indexPath.item] : 1
        let menu = PhotoContextMenuController(
            photoID: photoID, aspectRatio: aspectRatio, sourceFrame: sourceFrame, startFrame: startFrame,
            placeholderImage: placeholder, items: items
        ) { [weak self, weak photoCell] in
            photoCell?.isHiddenForMenu = false
            self?.contextMenuActive = false
        }
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        presenter?.present(menu, animated: false)
    }

    /// 拖到可见区域上下边缘时自动滚屏（交互式移动不自带），速度按深入程度平方增长
    private func updateReorderAutoScroll(for location: CGPoint) {
        guard let collectionView else { return }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let edge = min(80, visible.height / 4)
        let depth: CGFloat
        if location.y < visible.minY + edge {
            depth = -min((visible.minY + edge - location.y) / edge, 1)
        } else if location.y > visible.maxY - edge {
            depth = min((location.y - (visible.maxY - edge)) / edge, 1)
        } else {
            depth = 0
        }
        reorderAutoScrollVelocity = depth * abs(depth) * 1200
        if reorderAutoScrollVelocity == 0 {
            stopReorderAutoScroll()
        } else if reorderAutoScrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(reorderAutoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            reorderAutoScrollLink = link
        }
    }

    @objc private func reorderAutoScrollTick(_ link: CADisplayLink) {
        guard let collectionView, let recognizer = reorderRecognizer, let press = reorderPress, press.isMoving else {
            stopReorderAutoScroll()
            return
        }
        let elapsed = min(link.targetTimestamp - link.timestamp, 1.0 / 30)
        let insets = collectionView.adjustedContentInset
        let minY = -insets.top
        let maxY = max(minY, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        let nextY = min(max(collectionView.contentOffset.y + reorderAutoScrollVelocity * CGFloat(elapsed), minY), maxY)
        guard nextY != collectionView.contentOffset.y else { return }
        collectionView.contentOffset.y = nextY
        // 手指不动、内容在动：按新的内容坐标更新被拖格子的位置
        let location = recognizer.location(in: collectionView)
        collectionView.updateInteractiveMovementTargetPosition(
            CGPoint(x: location.x + press.grabOffset.x, y: location.y + press.grabOffset.y))
    }

    private func stopReorderAutoScroll() {
        reorderAutoScrollLink?.invalidate()
        reorderAutoScrollLink = nil
        reorderAutoScrollVelocity = 0
    }

    #if DEBUG
    /// AUTO_HOLD 调试：按下 → 0.3s 识别 → 按住不动（每帧 ±1pt 抖动，同真机手指）直到菜单弹出；
    /// 逐帧打印照片在屏幕上的显示宽度（格子按 presentation 层换算，菜单出现后改量预览）
    func debugHold(index: Int) {
        guard let collectionView, let window = collectionView.window,
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else {
            return
        }
        let center = cell.center
        let base = cell.bounds.width
        pressDidTouchDown(at: center)
        let start = CACurrentMediaTime()
        var began = false
        var frame = 0
        let link = DebugDisplayLink { [weak self, weak cell] link in
            guard let self, let cell else { link.stop(); return }
            let t = CACurrentMediaTime() - start
            if !began, t >= Self.liftDuration {
                began = true
                self.beginPress(at: IndexPath(item: index, section: 0), location: center)
            } else if began, self.reorderPress != nil {
                frame += 1
                self.movePress(to: CGPoint(x: center.x + (frame % 2 == 0 ? 1 : -1), y: center.y))
            }
            var width: CGFloat = 0
            var midX: CGFloat = 0
            var source = "cell"
            if !((cell as? PhotoCollectionCell)?.isHiddenForMenu ?? false), let imageLayer = cell.contentView.subviews.first?.layer.presentation(),
               let windowLayer = window.layer.presentation() {
                let rect = imageLayer.convert(imageLayer.bounds, to: windowLayer)
                width = rect.width
                midX = rect.midX
            } else if let menu = window.rootViewController?.presentedViewController
                        ?? window.windowScene?.windows.first(where: \.isKeyWindow)?.rootViewController?.presentedViewController,
                      let preview = menu.view.subviews.first(where: { $0 is UIImageView }),
                      let layer = preview.layer.presentation() {
                width = layer.frame.width
                midX = layer.frame.midX
                source = "menu"
            }
            print(String(format: "HOLD t=%.3f %@ scale=%.4f midX=%.1f", t, source, width / base, midX))
            if t > 1.6 { link.stop() }
        }
        link.start()
    }
    #endif

    /// 浮起反馈由格子自己保存（见 PhotoCollectionCell.setPressLifted），布局刷新不会冲掉
    private func setLifted(_ lifted: Bool, cell: UICollectionViewCell, duration: TimeInterval) {
        (cell as? PhotoCollectionCell)?.setPressLifted(lifted, duration: duration)
    }
}

/// 相簿里长按的放大节奏：按下稍等后开始浮起，长按识别（震动）时正好到 1.1 倍，继续按住则接着缓慢放大，
/// 到弹出菜单时停住。整段是同一条减速曲线 x = 1 − (1 − u)³（u：从开始浮起到菜单弹出的时间进度）、一个动画，
/// 震动处速度连续 —— 拆成「浮起 ease-out + 按住」两段时，震动那一下会停住再起步
struct PressCurve {
    /// 浮起到 1.1 倍的时长（开始浮起 → 长按识别）
    let liftDuration: TimeInterval
    var totalDuration: TimeInterval { liftDuration + ReorderablePhotoGrid.Coordinator.menuDelayAfterLift }

    static let timing = CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)

    /// 终点倍数：让曲线在震动时刻正好走到 1.1 倍
    var finalScale: CGFloat {
        let reached = 1 - pow(1 - liftDuration / totalDuration, 3)
        return 1 + (PhotoCollectionCell.liftedScale - 1) / CGFloat(reached)
    }
}

// MARK: - Footer

private final class GridFooterView: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 容器

/// 网格的自有容器：SwiftUI 只管容器，网格的尺寸、位置与内容边距都由容器显式设置。
/// 捏合换档期间每帧都在改 contentOffset，必须保证没有别的机制同时在动它（均实测踩过）：
/// SwiftUI 排版时重设网格 frame/bounds 会冲掉滚动位置 —— 容器只改 bounds.size（保留 origin）与 center；
/// 系统自动内容边距一旦变化会平移 contentOffset —— 网格关闭自动边距，由容器按自己的安全区设置
final class PhotoGridContainerView: UIView {
    let collectionView: UICollectionView

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        super.init(frame: .zero)
        collectionView.contentInsetAdjustmentBehavior = .never
        addSubview(collectionView)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = UIEdgeInsets(top: safeAreaInsets.top, left: 0, bottom: safeAreaInsets.bottom, right: 0)
        if collectionView.contentInset != insets {
            collectionView.contentInset = insets
            collectionView.verticalScrollIndicatorInsets = insets
        }
        if collectionView.bounds.size != bounds.size {
            collectionView.bounds.size = bounds.size
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if collectionView.center != center {
            collectionView.center = center
        }
    }
}

#if DEBUG
/// 闭包版 CADisplayLink（调试用）
final class DebugDisplayLink: NSObject {
    private var link: CADisplayLink?
    private let tick: (DebugDisplayLink) -> Void

    init(tick: @escaping (DebugDisplayLink) -> Void) {
        self.tick = tick
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        tick(self)
    }
}
#endif
