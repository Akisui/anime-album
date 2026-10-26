import SwiftUI
import UIKit

/// 查看顺序「连续从上到下」：所有图片按屏宽竖排成一条、之间没有间隙（像 PDF 连续滚动），整条一起缩放。
/// 只为可见范围附近的图片建视图；当前张 = 屏幕中线所在的那张
struct ContinuousStripView: UIViewRepresentable {
    let items: [ViewerItem]
    @Binding var index: Int
    let box: ContinuousStripBox
    var onSingleTap: () -> Void
    var onZoomChanged: (Bool) -> Void
    /// 当前张图片就绪（打开过渡据此让位）
    var onImageReady: (String) -> Void

    // MARK: 布局（查看器的打开过渡也按这里算落点，两边必须一致）

    static func frames(of items: [ViewerItem], width: CGFloat) -> [CGRect] {
        var y: CGFloat = 0
        return items.map { item in
            let height = width / max(item.aspectRatio, 0.01)
            defer { y += height }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
    }

    /// 内容比屏幕矮时上下居中（contentInset.top）
    static func topInset(frames: [CGRect], viewport: CGSize) -> CGFloat {
        max((viewport.height - (frames.last?.maxY ?? 0)) / 2, 0)
    }

    /// 打开 / 跳到第 index 张时的滚动位置：比屏幕矮的居中，比屏幕高的顶端对齐；不超出内容两端
    static func offsetY(toShow index: Int, frames: [CGRect], viewport: CGSize) -> CGFloat {
        guard frames.indices.contains(index) else { return 0 }
        let inset = topInset(frames: frames, viewport: viewport)
        guard inset == 0 else { return -inset }
        let frame = frames[index]
        let desiredTop = frame.height < viewport.height ? (viewport.height - frame.height) / 2 : 0
        let maxOffset = max((frames.last?.maxY ?? 0) - viewport.height, 0)
        return min(max(frame.minY - desiredTop, 0), maxOffset)
    }

    /// 打开时第 index 张在屏幕上的位置（过渡的落点）
    static func landingRect(items: [ViewerItem], index: Int, container: CGSize) -> CGRect {
        let frames = frames(of: items, width: container.width)
        guard frames.indices.contains(index) else { return CGRect(origin: .zero, size: container) }
        return frames[index].offsetBy(dx: 0, dy: -offsetY(toShow: index, frames: frames, viewport: container))
    }

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let coordinator = context.coordinator
        let scrollView = StripScrollView()
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.onLayout = { [weak coordinator] in coordinator?.handleLayout() }
        scrollView.addSubview(coordinator.contentView)
        coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        box.frameOfItem = { [weak coordinator] id in coordinator?.windowFrame(ofItemID: id) }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        let itemsChanged = coordinator.parent.items.map(\.id) != items.map(\.id)
        coordinator.parent = self
        if itemsChanged {
            coordinator.reloadItems()
        } else if index != coordinator.reportedIndex {
            // 外部换页（点胶片条）：滚到那张
            coordinator.scroll(to: index, animated: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ContinuousStripView
        weak var scrollView: UIScrollView?
        let contentView = UIView()
        private var frames: [CGRect] = []
        private var pageViews: [Int: StripPageView] = [:]
        private var laidOutWidth: CGFloat = 0
        /// 最近一次由滚动算出 / 已对齐的页码（与外部 index 不同时说明是外部要求换页）
        private(set) var reportedIndex: Int

        init(_ parent: ContinuousStripView) {
            self.parent = parent
            reportedIndex = parent.index
        }

        private var viewport: CGSize {
            scrollView?.bounds.size ?? .zero
        }

        func handleLayout() {
            guard let scrollView, scrollView.bounds.width > 0 else { return }
            if scrollView.bounds.width != laidOutWidth {
                laidOutWidth = scrollView.bounds.width
                rebuildLayout()
                scroll(to: parent.index, animated: false)
            }
            updateVisiblePages()
        }

        func reloadItems() {
            for view in pageViews.values {
                view.removeFromSuperview()
            }
            pageViews = [:]
            rebuildLayout()
            scroll(to: parent.index, animated: false)
            updateVisiblePages()
        }

        private func rebuildLayout() {
            guard let scrollView else { return }
            // 宽度变了（转屏 / 分屏）或换了内容：回到不缩放再排
            scrollView.zoomScale = 1
            frames = ContinuousStripView.frames(of: parent.items, width: scrollView.bounds.width)
            let height = frames.last?.maxY ?? 0
            contentView.frame = CGRect(x: 0, y: 0, width: scrollView.bounds.width, height: height)
            scrollView.contentSize = contentView.frame.size
            let inset = ContinuousStripView.topInset(frames: frames, viewport: viewport)
            scrollView.contentInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
            for (index, view) in pageViews {
                if frames.indices.contains(index) {
                    view.frame = frames[index]
                }
            }
        }

        func scroll(to index: Int, animated: Bool) {
            guard let scrollView, frames.indices.contains(index) else { return }
            reportedIndex = index
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: false)
            }
            let y = ContinuousStripView.offsetY(toShow: index, frames: frames, viewport: viewport)
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
            updateVisiblePages()
        }

        /// 可见范围上下各多留一屏建视图，其余回收
        private func updateVisiblePages() {
            guard let scrollView, !frames.isEmpty else { return }
            let visible = scrollView.convert(scrollView.bounds, to: contentView)
            let range = visible.insetBy(dx: 0, dy: -visible.height)
            for (index, view) in pageViews where !frames[index].intersects(range) {
                view.removeFromSuperview()
                pageViews[index] = nil
            }
            for (index, frame) in frames.enumerated() where frame.intersects(range) && pageViews[index] == nil {
                let item = parent.items[index]
                let view = StripPageView(item: item) { [weak self] in
                    guard let self else { return }
                    if index == self.parent.index {
                        self.parent.onImageReady(item.id)
                    }
                }
                view.frame = frame
                view.setZoomed(scrollView.zoomScale > 1.15)
                contentView.addSubview(view)
                pageViews[index] = view
            }
        }

        /// 屏幕中线所在的那张
        private func centeredIndex() -> Int? {
            guard let scrollView, !frames.isEmpty else { return nil }
            let visible = scrollView.convert(scrollView.bounds, to: contentView)
            let midY = visible.midY
            return frames.firstIndex { $0.minY <= midY && midY < $0.maxY }
                ?? (midY < 0 ? 0 : frames.count - 1)
        }

        func windowFrame(ofItemID id: String) -> CGRect? {
            guard let index = parent.items.firstIndex(where: { $0.id == id }), let view = pageViews[index],
                  view.window != nil
            else {
                return nil
            }
            return view.convert(view.bounds, to: nil)
        }

        // MARK: 手势

        @objc func handleSingleTap() {
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: contentView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                           width: size.width, height: size.height), animated: true)
            }
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.15
            for view in pageViews.values {
                view.setZoomed(zoomed)
            }
            parent.onZoomChanged(scrollView.zoomScale > 1.02)
            updateVisiblePages()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisiblePages()
            // 只有用户滚动才改页码；程序滚动（点胶片条跳页）途经的各张不算
            guard scrollView.isTracking || scrollView.isDecelerating || scrollView.isZooming,
                  let index = centeredIndex(), index != reportedIndex
            else {
                return
            }
            reportedIndex = index
            parent.index = index
        }
    }
}

/// 打开 / 关闭过渡向连续长条查询某张图当前在屏幕上的位置
final class ContinuousStripBox {
    var frameOfItem: ((String) -> CGRect?)?
}

private final class StripScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// 长条里的一张：预览图；PDF 矢量页放大后叠分块重绘层，扫描页放大后换原图
private final class StripPageView: UIImageView {
    private let item: ViewerItem
    private var tiledView: UIView?
    private var fullImageRequested = false
    private var loadTask: Task<Void, Never>?

    init(item: ViewerItem, onReady: @escaping () -> Void) {
        self.item = item
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = .secondarySystemFill
        image = item.cachedImage(.large) ?? item.cachedImage(.small) ?? item.cachedImage(.tiny)
        if item.isVectorPage, let page = item.page {
            let tiled = PDFTiledPageView(photoID: item.photoID, page: page)
            tiled.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tiled.isHidden = true
            addSubview(tiled)
            tiledView = tiled
        }
        loadTask = Task { [weak self] in
            let image = await item.image(.large)
            guard let self, !Task.isCancelled else { return }
            if let image {
                self.image = image
                self.backgroundColor = .clear
            }
            onReady()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tiledView?.frame = bounds
    }

    func setZoomed(_ zoomed: Bool) {
        if let tiledView, tiledView.isHidden == zoomed {
            tiledView.isHidden = !zoomed
        }
        guard zoomed, !fullImageRequested, let page = item.page, !item.isVectorPage else { return }
        fullImageRequested = true
        let item = item
        Task { [weak self] in
            guard let image = await PDFPageStore.shared.fullImage(photoID: item.photoID, page: page) else { return }
            self?.image = image
        }
    }
}
