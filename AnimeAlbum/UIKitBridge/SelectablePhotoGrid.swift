import SwiftUI
import UIKit

/// 可滑动连选的照片网格（「添加到相簿」选择器用）：轻点切换单张，横向起手拖动连选、
/// 拖到边缘自动滚屏，纵向起手正常滚动 —— 手势逻辑见 SwipeSelectionController（与图库共用）。
///
/// 用 UICollectionView 而非 LazyVGrid：命中测试直接走布局属性，不依赖 SwiftUI 上报的格子 frame。
struct SelectablePhotoGrid: UIViewRepresentable {
    let photos: [Photo]
    @Binding var selectedIDs: Set<UUID>

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let collectionView = BottomAnchoredCollectionView(
            frame: .zero, collectionViewLayout: PhotoGridLayout.make(cellTarget: 110))
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = coordinator

        coordinator.configureDataSource(for: collectionView)
        coordinator.update(photos: photos)

        let swipe = coordinator.swipeSelection
        swipe.itemIndex = { [weak collectionView] point, exact in
            collectionView?.itemIndex(atWindowPoint: point, exact: exact)
        }
        swipe.onSelectionChange = { [weak coordinator] selection in
            coordinator?.parent.selectedIDs = selection
            coordinator?.refreshVisibleSelection()
        }
        swipe.attach(to: collectionView)
        syncSwipeSelection(coordinator)

        #if DEBUG
        // 调试辅助：AUTO_SWIPE=a-b 模拟一次从第 a 张连选到第 b 张，截图验证连选结果
        if let raw = ProcessInfo.processInfo.environment["AUTO_SWIPE"] {
            let bounds = raw.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2 {
                swipe.debugSimulate(from: bounds[0], to: bounds[1])
            }
        }
        #endif
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.update(photos: photos)
        syncSwipeSelection(coordinator)
        coordinator.refreshVisibleSelection()
    }

    private func syncSwipeSelection(_ coordinator: Coordinator) {
        coordinator.swipeSelection.itemIDs = photos.map(\.id)
        coordinator.swipeSelection.selection = selectedIDs
    }

    static func dismantleUIView(_ collectionView: UICollectionView, coordinator: Coordinator) {
        coordinator.swipeSelection.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var parent: SelectablePhotoGrid
        let swipeSelection = SwipeSelectionController()

        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
        private weak var collectionView: UICollectionView?

        init(_ parent: SelectablePhotoGrid) {
            self.parent = parent
        }

        func configureDataSource(for collectionView: UICollectionView) {
            self.collectionView = collectionView

            let cellRegistration = UICollectionView.CellRegistration<PhotoCollectionCell, UUID> {
                [weak self] cell, _, photoID in
                cell.configure(photoID: photoID)
                cell.setChecked(self?.parent.selectedIDs.contains(photoID) ?? false, animated: false)
            }
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) {
                collectionView, indexPath, photoID in
                collectionView.dequeueConfiguredReusableCell(
                    using: cellRegistration, for: indexPath, item: photoID)
            }
        }

        func update(photos: [Photo]) {
            let ids = photos.map(\.id)
            guard ids != dataSource.snapshot().itemIdentifiers else { return }

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        /// 选中集变化后只刷新可见单元的勾选态（不重载数据，图片不闪）
        func refreshVisibleSelection() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath) as? PhotoCollectionCell,
                      let photoID = dataSource.itemIdentifier(for: indexPath)
                else {
                    continue
                }
                cell.setChecked(parent.selectedIDs.contains(photoID), animated: true)
            }
        }
    }
}

// MARK: - UICollectionViewDelegate（轻点切换）

extension SelectablePhotoGrid.Coordinator: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let photoID = dataSource.itemIdentifier(for: indexPath) else { return }
        if parent.selectedIDs.contains(photoID) {
            parent.selectedIDs.remove(photoID)
        } else {
            parent.selectedIDs.insert(photoID)
        }
        refreshVisibleSelection()
    }
}
