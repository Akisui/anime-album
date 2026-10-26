import SwiftUI
import UIKit

/// 查看顺序「连续从上到下」：所有图片按屏宽竖排成一条、之间没有间隙（像 PDF 连续滚动）。
/// 缩放只作用于手指下的那一张（用户要求，不是整条一起放大）：每张图自己是一个可缩放的 UIScrollView，
/// 放大时整张跟着变大、不裁在原格子里（用户要求「格子也要一起放大」）—— 移到最上层盖住上下相邻的图，
/// 超出原格子的部分也能拖动 / 捏合；滑出屏幕后复原。
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
        #if DEBUG
        // CONT_ZOOM=1：2s 后对当前张做一次双击放大（只该放大这一张）
        if ProcessInfo.processInfo.environment["CONT_ZOOM"] == "1" {
            Task { @MainActor [weak coordinator] in
                try? await Task.sleep(for: .seconds(2))
                coordinator?.debugZoomCurrent()
            }
        }
        #endif
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
            // 放大过的图完全滑出屏幕后复原
            for (index, view) in pageViews where view.zoomScale > 1 && !frames[index].intersects(visible) {
                view.setZoomScale(1, animated: false)
            }
            for (index, frame) in frames.enumerated() where frame.intersects(range) && pageViews[index] == nil {
                let item = parent.items[index]
                let view = StripPageView(item: item) { [weak self] in
                    guard let self else { return }
                    if index == self.parent.index {
                        self.parent.onImageReady(item.id)
                    }
                }
                view.onZoomChanged = { [weak self] in self?.reportZoom() }
                view.frame = frame
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

        /// 双击：只放大 / 复原点到的那一张
        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: contentView)
            guard let view = pageViews.values.first(where: { $0.frame.contains(point) }) else { return }
            view.toggleZoom(at: recognizer.location(in: view.imageView))
        }

        #if DEBUG
        func debugZoomCurrent() {
            guard let view = pageViews[parent.index] else { return }
            view.toggleZoom(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        }
        #endif

        private func reportZoom() {
            parent.onZoomChanged(pageViews.values.contains { $0.zoomScale > 1.02 })
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisiblePages()
            // 只有用户滚动才改页码；程序滚动（点胶片条跳页）途经的各张不算
            guard scrollView.isTracking || scrollView.isDecelerating,
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

/// 长条里的一张：自己可缩放（放大后不裁剪、盖住相邻的图，超出原格子的部分也接收触摸）。预览图；PDF 矢量页放大后叠分块重绘层，扫描页放大后换原图
private final class StripPageView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onZoomChanged: (() -> Void)?
    private let item: ViewerItem
    private var tiledView: UIView?
    private var fullImageRequested = false
    private var loadTask: Task<Void, Never>?

    init(item: ViewerItem, onReady: @escaping () -> Void) {
        self.item = item
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        // 不放大时不拦竖向滑动，交给外层长条
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        bouncesZoom = true
        // 放大后的图画到格子外面（盖住相邻的图）
        clipsToBounds = false
        backgroundColor = .secondarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = item.cachedImage(.large) ?? item.cachedImage(.small) ?? item.cachedImage(.tiny)
        addSubview(imageView)
        if item.isVectorPage, let page = item.page {
            let tiled = PDFTiledPageView(photoID: item.photoID, page: page)
            tiled.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tiled.isHidden = true
            imageView.addSubview(tiled)
            tiledView = tiled
        }
        loadTask = Task { [weak self] in
            let image = await item.image(.large)
            guard let self, !Task.isCancelled else { return }
            if let image {
                self.imageView.image = image
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

    override var frame: CGRect {
        didSet {
            guard frame.size != oldValue.size else { return }
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: frame.size)
            tiledView?.frame = imageView.bounds
            contentSize = frame.size
        }
    }

    func toggleZoom(at point: CGPoint) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if zoomScale > 1 {
            superview?.bringSubviewToFront(self)
        }
        updateDetail(zoomed: zoomScale > 1.15)
        onZoomChanged?()
    }

    /// 放大后整张图的范围都算在内：手指放在盖住相邻格子的那部分上也能拖动 / 捏合
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if zoomScale > 1.01 {
            return imageView.frame.contains(point)
        }
        return super.point(inside: point, with: event)
    }

    /// 放大后：矢量页显示分块重绘层；扫描页换原图（同比例）
    private func updateDetail(zoomed: Bool) {
        if let tiledView, tiledView.isHidden == zoomed {
            tiledView.isHidden = !zoomed
        }
        guard zoomed, !fullImageRequested, let page = item.page, !item.isVectorPage else { return }
        fullImageRequested = true
        let item = item
        Task { [weak self] in
            guard let image = await PDFPageStore.shared.fullImage(photoID: item.photoID, page: page) else { return }
            self?.imageView.image = image
        }
    }
}
