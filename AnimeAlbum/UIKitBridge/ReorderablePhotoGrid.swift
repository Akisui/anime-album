import SwiftUI
import UIKit

/// 相簿内照片网格（DESIGN.md §6.4）：用 UICollectionView 桥接实现，
/// 只有 UIKit 的 drag & drop 才能获得原生照片 App 同款的浮起/让位/自动滚屏排序手感。
/// 同时支持捏合缩放列数、Context Menu、点按回调。
struct ReorderablePhotoGrid: UIViewRepresentable {
    let photos: [Photo]
    var onTap: (Int) -> Void
    var onMove: (UUID, Int) -> Void
    var onSetCover: (UUID) -> Void
    var onRemove: (UUID) -> Void
    /// 供查看器查询单元当前全局 frame（自绘 zoom 过渡的起点/落点）
    var frameBox: GridFrameBox?
    /// 正在查看器中的照片：其单元渲染为空白，关闭动画结束后恢复
    var hiddenPhotoID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: Coordinator.makeLayout(zoomLevel: coordinator.zoomLevel))
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = coordinator
        collectionView.dragDelegate = coordinator
        collectionView.dropDelegate = coordinator
        collectionView.dragInteractionEnabled = true

        let pinch = UIPinchGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        collectionView.addGestureRecognizer(pinch)

        coordinator.configureDataSource(for: collectionView)
        coordinator.update(photos: photos)
        frameBox?.lookup = { [weak coordinator] photoID in
            coordinator?.frameOfCell(photoID: photoID)
        }
        // 未被导航栏/Home 指示条遮挡的可见区域（窗口坐标）：查看器过渡按它裁切
        frameBox?.visibleRect = { [weak collectionView] in
            guard let collectionView, collectionView.window != nil else { return nil }
            let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
            return collectionView.convert(visible, to: nil)
        }
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(photos: photos)
        context.coordinator.updateHiddenPhoto(hiddenPhotoID)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var parent: ReorderablePhotoGrid
        var zoomLevel = 1
        private static let cellTargets: [CGFloat] = [76, 110, 168]

        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
        private var photosByID: [UUID: Photo] = [:]
        private weak var collectionView: UICollectionView?

        init(_ parent: ReorderablePhotoGrid) {
            self.parent = parent
        }

        // MARK: 布局

        static func makeLayout(zoomLevel: Int) -> UICollectionViewCompositionalLayout {
            let target = cellTargets[max(0, min(zoomLevel, cellTargets.count - 1))]
            return UICollectionViewCompositionalLayout { _, environment in
                let spacing: CGFloat = 2
                let width = environment.container.effectiveContentSize.width
                let columns = max(1, Int((width + spacing) / (target + spacing)))
                let itemWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)

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
                section.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1), heightDimension: .absolute(64)),
                        elementKind: UICollectionView.elementKindSectionFooter,
                        alignment: .bottom),
                ]
                return section
            }
        }

        func configureDataSource(for collectionView: UICollectionView) {
            self.collectionView = collectionView

            let cellRegistration = UICollectionView.CellRegistration<PhotoCollectionCell, UUID> {
                [weak self] cell, _, photoID in
                cell.configure(photoID: photoID, photo: self?.photosByID[photoID])
                cell.isHidden = photoID == self?.hiddenPhotoID
            }
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) {
                collectionView, indexPath, photoID in
                collectionView.dequeueConfiguredReusableCell(
                    using: cellRegistration, for: indexPath, item: photoID)
            }

            let footerRegistration = UICollectionView.SupplementaryRegistration<GridFooterView>(
                elementKind: UICollectionView.elementKindSectionFooter
            ) { [weak self] footer, _, _ in
                let count = self?.dataSource.snapshot().numberOfItems ?? 0
                footer.label.text = "\(count) 张照片"
            }
            dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
                collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
            }
        }

        func update(photos: [Photo]) {
            photosByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
            let ids = photos.map(\.id)
            guard ids != dataSource.snapshot().itemIdentifiers else { return }

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            dataSource.apply(snapshot, animatingDifferences: true)
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

        // MARK: 捏合缩放列数

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .changed else { return }
            if recognizer.scale > 1.35, zoomLevel < Self.cellTargets.count - 1 {
                zoomLevel += 1
            } else if recognizer.scale < 0.72, zoomLevel > 0 {
                zoomLevel -= 1
            } else {
                return
            }
            recognizer.scale = 1
            collectionView?.setCollectionViewLayout(Self.makeLayout(zoomLevel: zoomLevel), animated: true)
        }

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
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        parent.onTap(indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
              let photoID = dataSource.itemIdentifier(for: indexPath)
        else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let setCover = UIAction(
                title: "设为封面", image: UIImage(systemName: "photo.badge.checkmark")
            ) { _ in
                self?.parent.onSetCover(photoID)
            }
            let remove = UIAction(
                title: "从相簿中移除",
                image: UIImage(systemName: "rectangle.stack.badge.minus"),
                attributes: .destructive
            ) { _ in
                self?.parent.onRemove(photoID)
            }
            return UIMenu(children: [setCover, remove])
        }
    }
}

// MARK: - Drag & Drop（原生排序手感的来源）

extension ReorderablePhotoGrid.Coordinator: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let photoID = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let dragItem = UIDragItem(itemProvider: NSItemProvider())
        dragItem.localObject = photoID
        return [dragItem]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionWillBegin session: UIDragSession) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

extension ReorderablePhotoGrid.Coordinator: UICollectionViewDropDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil else {
            return UICollectionViewDropProposal(operation: .cancel)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard coordinator.proposal.operation == .move,
              let item = coordinator.items.first,
              let sourceIndexPath = item.sourceIndexPath,
              let photoID = item.dragItem.localObject as? UUID
        else {
            return
        }

        var snapshot = dataSource.snapshot()
        let count = snapshot.numberOfItems
        var destination = coordinator.destinationIndexPath ?? IndexPath(item: count - 1, section: 0)
        destination.item = max(0, min(destination.item, count - 1))

        guard destination != sourceIndexPath else {
            coordinator.drop(item.dragItem, toItemAt: sourceIndexPath)
            return
        }

        let destinationID = snapshot.itemIdentifiers[destination.item]
        snapshot.deleteItems([photoID])
        if destination.item > sourceIndexPath.item {
            snapshot.insertItems([photoID], afterItem: destinationID)
        } else {
            snapshot.insertItems([photoID], beforeItem: destinationID)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        coordinator.drop(item.dragItem, toItemAt: destination)

        parent.onMove(photoID, destination.item)
    }
}

// MARK: - Cell / Footer

private final class PhotoCollectionCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(photoID: UUID, photo: Photo?) {
        loadTask?.cancel()
        imageView.image = nil
        loadTask = Task { [weak self] in
            let image = await ThumbnailCache.shared.image(for: photoID, kind: .small)
            guard let self, !Task.isCancelled else { return }
            self.imageView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        imageView.image = nil
    }
}

private final class GridFooterView: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
