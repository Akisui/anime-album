import SwiftUI

// MARK: - 呈现状态

@MainActor
@Observable
final class ViewerPresenter {
    struct Session {
        let photos: [Photo]
        let initialIndex: Int
        /// 按照片 ID 查询其网格单元当前的全局 frame（打开起点 / 关闭落点）；不可见返回 nil
        let sourceFrame: (UUID) -> CGRect?
        /// 网格未被 bar 遮挡的可见区域（全局坐标）：过渡图层按它裁切，
        /// 格子被导航栏/Tab 栏遮住的部分不会在过渡中"穿透"显示到 bar 之上
        let sourceVisibleRect: () -> CGRect?
    }

    private(set) var session: Session?
    /// 沉浸模式：隐藏工具栏与状态栏、背景纯黑；否则背景跟随系统背景色（与原生一致）
    var chromeHidden = false
    /// 当前在查看器中的照片：其网格格子渲染为空白（图片"离开/回到"格子的逻辑），
    /// 关闭动画完全结束（end()）时才恢复显示
    private(set) var hiddenPhotoID: UUID?

    func present(
        photos: [Photo], index: Int,
        sourceFrame: @escaping (UUID) -> CGRect?,
        sourceVisibleRect: @escaping () -> CGRect? = { nil }
    ) {
        guard session == nil, photos.indices.contains(index) else { return }
        chromeHidden = false
        hiddenPhotoID = photos[index].id
        session = Session(
            photos: photos, initialIndex: index,
            sourceFrame: sourceFrame, sourceVisibleRect: sourceVisibleRect)
    }

    func setHiddenPhoto(_ id: UUID?) {
        hiddenPhotoID = id
    }

    func end() {
        session = nil
        chromeHidden = false
        hiddenPhotoID = nil
    }
}

/// SwiftUI 网格（图库）持续上报可见单元的全局 frame
final class CellFrameStore {
    var frames: [UUID: CGRect] = [:]
    /// 网格未被 bar 遮挡的可见区域（全局坐标）
    var visibleRect: CGRect?
}

/// UIKit 网格（相簿详情）向查看器提供单元 frame 查询的桥
final class GridFrameBox {
    var lookup: ((UUID) -> CGRect?)?
    /// 网格未被 bar 遮挡的可见区域（全局坐标）
    var visibleRect: (() -> CGRect?)?
}

// MARK: - 查看器 overlay

/// 全屏照片查看器（DESIGN.md §6.3）。挂在 RootView 顶层 overlay，不走系统呈现，
/// 过渡完全自绘（系统 navigationTransition(.zoom) 方案已放弃，原因见 CLAUDE.md 已知坑）。
///
/// 无缝切换的关键设计：翻页器从打开那一刻就挂载在过渡图层下方预加载（透明），
/// 过渡动画结束且当前页图片就绪后才让位 —— 两者矩形逐像素重合，切换无闪烁；
/// 下拉拖拽同理，移动的始终是轻量的单图层（翻页器不参与），不会与其内部手势打架。
struct PhotoViewerOverlay: View {
    let session: ViewerPresenter.Session

    @Environment(ViewerPresenter.self) private var presenter

    private enum Phase {
        case opening
        case presented
        case dragging
        case closing
    }

    @State private var phase: Phase = .opening
    @State private var index: Int
    @State private var containerSize: CGSize = .zero
    @State private var backdropOpacity: Double = 0
    @State private var transitionRect: CGRect = .zero
    @State private var transitionImage: UIImage?
    @State private var transitionOpacity: Double = 1
    /// 过渡图层的裁切窗（全局坐标）：打开时从「格子 ∩ 网格可见区域」展开到全屏，
    /// 关闭时反向收拢 —— 格子被导航栏/Tab 栏遮住的部分在过渡中保持被遮，
    /// 从 bar 底下滑出/缩回（原生同款），而不是瞬间穿透显示到 bar 之上
    @State private var maskRect: CGRect = .zero
    @State private var dragFitRect: CGRect = .zero
    @State private var draggingPhotoID: UUID?
    /// 拖拽开始到关闭结束期间压住查看器 bar：避免松手瞬间 bar 跟随 backdropOpacity
    /// 突然闪现在缩略图页的 bar 上（两者高度还不一致）
    @State private var chromeSuppressed = false
    /// bar 隐藏方式：单击触发时向上滑出/向下滑入，放大手势触发时纯淡出（用户要求区分）
    @State private var chromeSlides = false
    /// 沉浸黑色量（0=系统背景色，1=纯黑）。背景层与 bar 底色共读这一个值，
    /// 保证黑色量每帧逐像素相等 —— 若两处各写 `chromeHidden ? 1 : 0` 会各自插值、出现色差缝
    @State private var immersiveAmount: Double = 0
    /// 当前隐藏动作发生时，bar 后面是否是图片（侵入）。是则 bar 底色不随沉浸变黑（纯透明化露出图片），
    /// 否则（bar 后面是背景）底色跟背景一起变黑以避免色差缝
    @State private var barOverImage = false
    /// 打开时（状态栏可见）捕获的状态栏高度，作为稳定值：进入沉浸后状态栏隐藏、
    /// statusBarFrame 会变 0，若实时读取会导致 bar 布局与滑出距离塌陷
    @State private var stableSafeTop: CGFloat = 0
    @State private var openAnimationDone = false
    @State private var readyPages: Set<UUID> = []
    @State private var zoomedPages: Set<UUID> = []
    /// 每页当前显示的图片顶边（窗口坐标 Y），由 ZoomableImageView 实时上报（含缩放/平移）
    @State private var imageTops: [UUID: CGFloat] = [:]

    /// 每页缩放状态由页面的代理回调维护（含离屏自动复位），跨页切换不丢失
    private var currentPageZoomed: Bool {
        zoomedPages.contains(currentPhoto.id)
    }

    /// bar 高度对齐系统 inline 导航栏（44pt），使查看器 bar 底边与缩略图页 bar 底边一致
    private static let barHeight: CGFloat = 44

    /// 状态栏高度（实时读取）。系统导航栏把内容放在状态栏下方（而非完整 safeArea 下方，
    /// 后者约大 5.7pt）；仅在打开时捕获一次存入 stableSafeTop，之后一律用稳定值
    private var liveStatusBarHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let h = scene?.statusBarManager?.statusBarFrame.height, h > 0 {
            return h
        }
        return scene?.windows.first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
    }

    /// 顶部 bar 底边的屏幕 Y（状态栏 + bar 高度）；用稳定值，不受沉浸后状态栏隐藏影响
    private var barBottomY: CGFloat {
        stableSafeTop + Self.barHeight
    }

    /// 当前图片是否有内容侵入 bar 区域：放大态一定侵入；否则看 fit 矩形顶边是否伸进 bar
    private var imageIntrudesBar: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FORCE_INTRUDE"] == "1" { return true }
        #endif
        // 优先用实时上报的图片顶边（含缩放/平移）；未上报时退回 fit 矩形估算
        if let top = imageTops[currentPhoto.id] {
            return top < barBottomY - 1
        }
        let image = loadTransitionImage(for: currentPhoto)
        let fit = fitRect(for: imageSize(of: currentPhoto, image: image), in: containerSize)
        return fit.minY < barBottomY - 1
    }

    /// SLOW_ANIM=1 时把过渡动画拉长 8 倍（仅 DEBUG），供逐帧截图验证；
    /// SwiftUI 动画不受 window.layer.speed 影响，只能在时长上做
    private static let slowFactor: Double = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SLOW_ANIM"] == "1" ? 8 : 1
        #else
        return 1
        #endif
    }()

    init(session: ViewerPresenter.Session) {
        self.session = session
        _index = State(initialValue: session.initialIndex)
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    // 背景两层叠加：底层系统背景色，上盖黑色层以透明度切换 —— 沉浸时黑层淡入。
                    // 用 opacity 动画（而非切换 fill 颜色）才能与 bar 同事务同步，不割裂。
                    ZStack {
                        Rectangle().fill(Color(.systemBackground))
                        Rectangle().fill(Color.black).opacity(immersiveAmount)
                    }
                    .opacity(backdropOpacity)

                    pager
                        .opacity(phase == .presented ? 1 : 0)
                        .allowsHitTesting(phase == .presented)

                    if phase != .presented, let transitionImage {
                        let mask = maskRect.isEmpty
                            ? CGRect(origin: .zero, size: containerSize) : maskRect
                        Image(uiImage: transitionImage)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: max(transitionRect.width, 1),
                                height: max(transitionRect.height, 1))
                            .clipped()
                            .position(x: transitionRect.midX, y: transitionRect.midY)
                            .mask {
                                Rectangle()
                                    .frame(width: max(mask.width, 1), height: max(mask.height, 1))
                                    .position(x: mask.midX, y: mask.midY)
                            }
                            .opacity(transitionOpacity)
                    }
                }
                .simultaneousGesture(dismissDrag)
                .onAppear {
                    containerSize = proxy.size
                    beginOpen()
                }
            }
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                containerSize = newSize
            }

            // bar 常驻（顶端对齐由 VStack+Spacer 负责），淡出用 opacity（bar 持续重渲染，
            // 底色随 immersiveAmount 与背景同步变黑，无色差缝）；滑动用 offset。
            // chrome 现在是 bar 自身高度（Spacer 在外），offset 才能按 bar 高度正确移出。
            VStack(spacing: 0) {
                chrome
                    // 必须先 compositingGroup 再 opacity：否则淡出时白底层与黑层各自降透明、
                    // 背景透上来使 bar 偏亮、与背景差 ~10 级
                    .compositingGroup()
                    .opacity(chromeOpacity)
                    .offset(y: chromeOffsetY)
                    .allowsHitTesting(chromeInteractive)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        }
        #if DEBUG
        // 调试：AUTO_IMMERSIVE=1 触发放大式（纯淡出）；AUTO_SLIDE=1 触发单击滑动式隐藏。便于逐帧截图
        .onChange(of: phase) {
            guard phase == .presented, !presenter.chromeHidden else { return }
            let env = ProcessInfo.processInfo.environment
            if env["AUTO_IMMERSIVE"] == "1" {
                Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    setChrome(hidden: true, slide: false)
                }
            } else if env["AUTO_SLIDE"] == "1" {
                Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    setChrome(hidden: true, slide: true)
                }
            } else if env["AUTO_TAP"] == "1" {
                // 走真实单击逻辑（按 imageIntrudesBar 决定滑动/淡出），验证侵入判断
                Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    setChrome(hidden: true, slide: imageIntrudesBar)
                }
            }
        }
        #endif
    }

    /// 滑动式隐藏保持不透明（靠 offset 移出）；淡出式隐藏降到 0。拖拽期间压住。
    private var chromeOpacity: Double {
        if chromeSuppressed { return 0 }
        if presenter.chromeHidden {
            return chromeSlides ? backdropOpacity : 0
        }
        return backdropOpacity
    }

    /// 滑动式隐藏：整条 bar 上移出屏幕（移动量 = bar 底边）；其余为 0
    private var chromeOffsetY: CGFloat {
        (presenter.chromeHidden && chromeSlides) ? -barBottomY : 0
    }

    private var chromeInteractive: Bool {
        phase == .presented && !presenter.chromeHidden
    }

    // MARK: 翻页器

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(session.photos.enumerated()), id: \.element.id) { offset, photo in
                ZoomableImageView(
                    photo: photo,
                    isCurrent: offset == index,
                    onSingleTap: {
                        // 单击：图片侵入 bar 区域时用滑动式（滑开露出图片），
                        // 否则（bar 处无图片）用淡入淡出
                        setChrome(hidden: !presenter.chromeHidden, slide: imageIntrudesBar)
                    },
                    onZoomChanged: { zoomed in
                        if zoomed {
                            zoomedPages.insert(photo.id)
                        } else {
                            zoomedPages.remove(photo.id)
                        }
                        // 放大浏览时进入沉浸模式（与原生一致）：快速淡出式隐藏（图片已盖住 bar，
                        // 慢慢淡出会显得拖沓）
                        if zoomed, offset == index, !presenter.chromeHidden {
                            setChrome(hidden: true, slide: false, duration: 0.12)
                        }
                    },
                    onImageReady: {
                        readyPages.insert(photo.id)
                        finishOpenIfReady()
                    },
                    onImageTopChanged: { top in
                        imageTops[photo.id] = top
                    }
                )
                // TabView 的分页容器会给每一页重新注入安全区，页内也必须显式忽略，
                // 否则页内 fit 布局与过渡层错位，交接瞬间图片会向下跳
                .ignoresSafeArea()
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // 页面必须真正全屏（刘海、底部指示条区域都可显示内容）
        .ignoresSafeArea()
        .onChange(of: index) {
            // 拖拽接管时 TabView 的翻页手势被取消，可能瞬时抖动 index 再弹回，
            // 只在正常浏览状态下联动空白格子，避免邻居缩略图闪空白
            guard phase == .presented else { return }
            presenter.setHiddenPhoto(currentPhoto.id)
        }
    }

    /// 顶部工具栏（仅 bar 自身高度 = 状态栏 + 44，不含撑满的 Spacer —— 顶端对齐由外层负责，
    /// transition 才能按 bar 高度精确滑动）。手动下移 stableSafeTop 使内容与系统 inline 导航栏
    /// 逐点对齐；底色跟随背景，沉浸时白→黑（bar 后是图片时不变黑）。
    private var chrome: some View {
        HStack {
            Button {
                beginClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight)
        .padding(.top, stableSafeTop)
        .background {
            // bar 后是背景时，底色随沉浸变黑并与背景逐像素相等（避免色差缝）；
            // bar 后是图片时（侵入），底色不变黑，淡出时纯透明化露出图片
            ZStack {
                Color(.systemBackground)
                Color.black.opacity(barOverImage ? 0 : immersiveAmount)
            }
        }
    }

    /// slide=true：位移隐藏（单击侵入时）；slide=false：纯淡出。
    /// chromeSlides / barOverImage 必须在动画外先置好，offset 与底色才会从正确起点插值。
    /// duration 可调：放大手势触发的淡出要更快（见调用处）。
    private func setChrome(hidden: Bool, slide: Bool, duration: Double = 0.25) {
        chromeSlides = slide
        barOverImage = imageIntrudesBar
        withAnimation(.easeInOut(duration: duration * Self.slowFactor)) {
            presenter.chromeHidden = hidden
            immersiveAmount = hidden ? 1 : 0
        }
    }

    // MARK: 打开

    private var currentPhoto: Photo {
        session.photos[max(0, min(index, session.photos.count - 1))]
    }

    private func beginOpen() {
        // 打开时状态栏可见，捕获稳定的状态栏高度供 bar 布局使用
        stableSafeTop = liveStatusBarHeight
        let photo = currentPhoto
        let image = loadTransitionImage(for: photo)
        transitionImage = image
        let target = fitRect(for: imageSize(of: photo, image: image), in: containerSize)
        // 预热大图（翻页器当前页也在同步加载，就绪后过渡层才让位）
        Task { _ = await ThumbnailCache.shared.image(for: photo.id, kind: .large) }

        let screen = CGRect(origin: .zero, size: containerSize)
        let visible = gridVisibleRect
        if let source = session.sourceFrame(photo.id), source.intersects(visible) {
            transitionRect = source
            maskRect = source.intersection(visible)
            transitionOpacity = 1
            withAnimation(
                .spring(response: 0.30 * Self.slowFactor, dampingFraction: 0.86),
                completionCriteria: .logicallyComplete
            ) {
                transitionRect = target
                maskRect = screen
                backdropOpacity = 1
            } completion: {
                openAnimationDone = true
                finishOpenIfReady()
            }
        } else {
            transitionRect = target.insetBy(dx: target.width * 0.06, dy: target.height * 0.06)
            maskRect = screen
            transitionOpacity = 0
            withAnimation(
                .easeOut(duration: 0.25 * Self.slowFactor), completionCriteria: .logicallyComplete
            ) {
                transitionRect = target
                transitionOpacity = 1
                backdropOpacity = 1
            } completion: {
                openAnimationDone = true
                finishOpenIfReady()
            }
        }
    }

    /// 过渡动画结束 + 当前页图片就绪，两个条件都满足才把画面交给翻页器（无缝）
    private func finishOpenIfReady() {
        guard phase == .opening, openAnimationDone, readyPages.contains(currentPhoto.id) else { return }
        phase = .presented
    }

    // MARK: 关闭

    private func beginClose() {
        guard phase == .presented || phase == .dragging else { return }
        // 拖拽发起的关闭以拖拽开始时锁定的照片为准，不受 index 瞬时抖动影响
        let photo: Photo
        if phase == .dragging, let dragID = draggingPhotoID,
           let dragged = session.photos.first(where: { $0.id == dragID }) {
            photo = dragged
        } else {
            photo = currentPhoto
        }
        if phase == .presented {
            // 从静止状态关闭：过渡层先在原位接管画面（与翻页器逐像素重合，切换无缝）
            let image = loadTransitionImage(for: photo)
            transitionImage = image
            transitionRect = fitRect(for: imageSize(of: photo, image: image), in: containerSize)
            transitionOpacity = 1
        }
        phase = .closing

        let screen = CGRect(origin: .zero, size: containerSize)
        let visible = gridVisibleRect
        maskRect = screen
        if let target = session.sourceFrame(photo.id), target.intersects(visible) {
            withAnimation(
                .spring(response: 0.28 * Self.slowFactor, dampingFraction: 0.88),
                completionCriteria: .logicallyComplete
            ) {
                transitionRect = target
                maskRect = target.intersection(visible)
                backdropOpacity = 0
            } completion: {
                // end() 同时恢复网格格子的显示 —— 图片"落回"格子的瞬间格子才重新出现
                presenter.end()
            }
        } else {
            // 落点单元不可见：原地缩小淡出
            let start = transitionRect
            withAnimation(
                .easeIn(duration: 0.22 * Self.slowFactor), completionCriteria: .logicallyComplete
            ) {
                transitionRect = start.insetBy(dx: start.width * 0.15, dy: start.height * 0.15)
                transitionOpacity = 0
                backdropOpacity = 0
            } completion: {
                presenter.end()
            }
        }
    }

    // MARK: 下拉拖拽（单图层跟手，翻页器不参与）

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !currentPageZoomed else { return }
                let translation = value.translation
                if phase == .presented {
                    // 只在明确向下的拖动时接管；水平方向留给翻页
                    guard translation.height > 6, translation.height > abs(translation.width) else { return }
                    enterDragMode()
                }
                guard phase == .dragging else { return }
                let progress = min(max(translation.height, 0) / 300, 1)
                let scale = 1 - 0.3 * progress
                let size = CGSize(width: dragFitRect.width * scale, height: dragFitRect.height * scale)
                let center = CGPoint(
                    x: dragFitRect.midX + translation.width,
                    y: dragFitRect.midY + translation.height)
                transitionRect = CGRect(
                    x: center.x - size.width / 2, y: center.y - size.height / 2,
                    width: size.width, height: size.height)
                backdropOpacity = 1 - progress
            }
            .onEnded { value in
                guard phase == .dragging else { return }
                if value.translation.height > 100 || value.predictedEndTranslation.height > 250 {
                    beginClose()
                } else {
                    withAnimation(
                        .spring(response: 0.28 * Self.slowFactor, dampingFraction: 0.85),
                        completionCriteria: .logicallyComplete
                    ) {
                        transitionRect = dragFitRect
                        backdropOpacity = 1
                    } completion: {
                        if phase == .dragging {
                            // 校正可能被取消手势抖走的页码，再交还给翻页器
                            if let dragID = draggingPhotoID,
                               let draggedIndex = session.photos.firstIndex(where: { $0.id == dragID }) {
                                index = draggedIndex
                            }
                            phase = .presented
                            presenter.setHiddenPhoto(currentPhoto.id)
                            // 弹回后恢复 bar（跟随 backdropOpacity 淡回）
                            withAnimation(.easeOut(duration: 0.2)) {
                                chromeSuppressed = false
                            }
                        }
                    }
                }
            }
    }

    private func enterDragMode() {
        let photo = currentPhoto
        let image = loadTransitionImage(for: photo)
        transitionImage = image
        draggingPhotoID = photo.id
        presenter.setHiddenPhoto(photo.id)
        chromeSuppressed = true
        dragFitRect = fitRect(for: imageSize(of: photo, image: image), in: containerSize)
        transitionRect = dragFitRect
        maskRect = CGRect(origin: .zero, size: containerSize)
        transitionOpacity = 1
        phase = .dragging
    }

    /// 网格未被 bar 遮挡的可见区域（全局坐标）；来源未提供时退回全屏
    private var gridVisibleRect: CGRect {
        let screen = CGRect(origin: .zero, size: containerSize)
        guard let visible = session.sourceVisibleRect() else { return screen }
        let clamped = visible.intersection(screen)
        return clamped.isEmpty ? screen : clamped
    }

    // MARK: 工具

    private func loadTransitionImage(for photo: Photo) -> UIImage? {
        ThumbnailCache.shared.cachedImage(for: photo.id, kind: .large)
            ?? ThumbnailCache.shared.cachedImage(for: photo.id, kind: .small)
            ?? ImageStore.shared.loadThumbnail(photoID: photo.id, kind: .small)
    }

    private func imageSize(of photo: Photo, image: UIImage?) -> CGSize {
        if let image {
            return image.size
        }
        if photo.width > 0, photo.height > 0 {
            return CGSize(width: photo.width, height: photo.height)
        }
        return containerSize
    }

    private func fitRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }
}
