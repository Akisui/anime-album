import SwiftUI
import UIKit

/// 查看器单页：UIScrollView 实现的双击/捏合缩放 + 平移（原生照片同款手感）。
/// 缩放时通知外层（缩放中禁用下拉关闭）；翻页离开时自动复位缩放。
struct ZoomableImageView: UIViewRepresentable {
    let photo: Photo
    let isCurrent: Bool
    var onSingleTap: () -> Void
    var onZoomChanged: (Bool) -> Void
    /// 图片加载并完成布局后回调（加载失败也会回调），供过渡层判断何时可无缝让位
    var onImageReady: (() -> Void)?
    /// 当前实际显示的图片顶边（窗口坐标 Y）变化时回调，供外层判断是否侵入顶部 bar
    var onImageTopChanged: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let coordinator = context.coordinator
        let scrollView = LayoutCallbackScrollView()
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.onLayout = { [weak coordinator] in
            coordinator?.handleLayoutChange()
        }

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        scrollView.addSubview(imageView)

        coordinator.scrollView = scrollView
        coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        coordinator.loadImage(photoID: photo.id)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        // 注意：不能在 isCurrent 变化（滑动过半）时复位缩放 —— 原生语义是
        // 页面完全滑出屏幕才复位；由 Coordinator 监听分页容器滚动实现
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private var loadTask: Task<Void, Never>?
        private var lastLayoutSize: CGSize = .zero
        private var pagingObservation: NSKeyValueObservation?

        init(_ parent: ZoomableImageView) {
            self.parent = parent
        }

        func loadImage(photoID: UUID) {
            loadTask = Task { [weak self] in
                let image = await ThumbnailCache.shared.image(for: photoID, kind: .large)
                guard let self, !Task.isCancelled else { return }
                if let image {
                    self.imageView?.image = image
                    self.layoutImage()
                }
                self.parent.onImageReady?()
            }
        }

        /// 按 aspect-fit 计算 imageView 尺寸并居中，可平移区域始终等于图像本身
        func layoutImage() {
            guard let scrollView, let imageView, let image = imageView.image,
                  scrollView.bounds.width > 0, scrollView.bounds.height > 0
            else {
                return
            }
            let boundsSize = scrollView.bounds.size
            let scale = min(boundsSize.width / image.size.width, boundsSize.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)

            scrollView.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            centerImage()
            reportImageTop()
        }

        func handleLayoutChange() {
            guard let scrollView else { return }
            attachPagingObserverIfNeeded()
            if scrollView.bounds.size != lastLayoutSize {
                lastLayoutSize = scrollView.bounds.size
                layoutImage()
            }
            reportImageTop()
        }

        /// 上报当前显示的图片顶边（窗口坐标）。缩放、平移、布局变化后都会调用
        func reportImageTop() {
            guard let imageView, imageView.window != nil else { return }
            let topInWindow = imageView.convert(imageView.bounds, to: nil).minY
            parent.onImageTopChanged?(topInWindow)
        }

        /// 监听分页容器（TabView 底层的 UIScrollView）的滚动：
        /// 本页完全滑出可视区域时才复位缩放（原生语义 —— 滑到一半又滑回来，缩放保持不变）
        private func attachPagingObserverIfNeeded() {
            guard pagingObservation == nil, let scrollView, scrollView.window != nil else { return }
            var ancestor = scrollView.superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let pagingScrollView = ancestor as? UIScrollView else { return }
            pagingObservation = pagingScrollView.observe(\.contentOffset) { [weak self] pagingScrollView, _ in
                MainActor.assumeIsolated {
                    self?.resetZoomIfFullyOffscreen(in: pagingScrollView)
                }
            }
        }

        private func resetZoomIfFullyOffscreen(in pagingScrollView: UIScrollView) {
            guard let scrollView, scrollView.zoomScale > 1.01 else { return }
            let frameInPaging = scrollView.convert(scrollView.bounds, to: pagingScrollView)
            let visible = CGRect(origin: pagingScrollView.contentOffset, size: pagingScrollView.bounds.size)
            if !frameInPaging.intersects(visible) {
                scrollView.setZoomScale(1, animated: false)
            }
        }

        private func centerImage() {
            guard let scrollView else { return }
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let insetX = max((bounds.width - content.width) / 2, 0)
            let insetY = max((bounds.height - content.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        // MARK: 手势

        @objc func handleSingleTap() {
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(
                    width: scrollView.bounds.width / scale,
                    height: scrollView.bounds.height / scale)
                let rect = CGRect(
                    origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                    size: size)
                scrollView.zoom(to: rect, animated: true)
            }
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
            parent.onZoomChanged(scrollView.zoomScale > 1.02)
            reportImageTop()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportImageTop()
        }
    }
}

private final class LayoutCallbackScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
