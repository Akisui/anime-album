import SwiftData
import SwiftUI

// MARK: - 呈现状态

@MainActor
@Observable
final class ViewerPresenter {
    struct Session {
        /// 一页一项（PDF 按页展开，见 ViewerItem）
        let items: [ViewerItem]
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

    /// photos 里的 PDF 按页展开；index 指 photos 里点开的那张，page 为 PDF 打开到的页
    func present(
        photos: [Photo], index: Int, page: Int = 0,
        sourceFrame: @escaping (UUID) -> CGRect?,
        sourceVisibleRect: @escaping () -> CGRect? = { nil }
    ) {
        guard session == nil, photos.indices.contains(index) else { return }
        let photoID = photos[index].id
        let items = ViewerItem.items(for: photos)
        guard let first = items.firstIndex(where: { $0.photoID == photoID }) else { return }
        let pages = items[first...].prefix { $0.photoID == photoID }.count
        chromeHidden = false
        hiddenPhotoID = photoID
        session = Session(
            items: items, initialIndex: first + max(0, min(page, pages - 1)),
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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortIndex) private var albums: [Album]

    private enum Phase {
        case opening
        case presented
        case dragging
        case closing
    }

    @State private var phase: Phase = .opening
    /// 查看中的各页（打开时取自 session；查看器里删除 / 编辑后在这里更新）
    @State private var items: [ViewerItem]
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
    @State private var draggingItemID: String?
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
    /// 底部安全区（Home 指示条）高度：胶片条在其上方，同样在打开时捕获一次
    @State private var stableSafeBottom: CGFloat = 0
    /// 胶片条居中的照片（与翻页器双向同步：翻页 → 胶片条滚到当前张；拖动胶片条 → 翻页器跟着换图）
    @State private var filmstripPosition = ScrollPosition(idType: String.self)
    /// 用户正在拖动 / 惯性滚动胶片条：此时当前张不展开（宽度变化会让滚动位置跳）
    @State private var isScrubbing = false
    @State private var openAnimationDone = false
    @State private var readyPages: Set<String> = []
    @State private var zoomedPages: Set<String> = []
    /// 每页当前显示的图片顶边（窗口坐标 Y），由 ZoomableImageView 实时上报（含缩放/平移）
    @State private var imageTops: [String: CGFloat] = [:]
    /// 「…」菜单：待确认删除的照片、正在裁剪的照片、新建相簿
    @State private var pendingDeletion: ViewerItem?
    @State private var editingItem: ViewerItem?
    @State private var showingNewAlbumAlert = false
    @State private var newAlbumName = ""
    @AppStorage("viewerReadingOrder") private var readingOrderRaw = ViewerReadingOrder.leftToRight.rawValue
    /// 连续长条模式下查询某张图在屏幕上的位置（关闭过渡的起点）
    @State private var continuousBox = ContinuousStripBox()

    /// 每页缩放状态由页面的代理回调维护（含离屏自动复位），跨页切换不丢失
    private var currentPageZoomed: Bool {
        zoomedPages.contains(currentItem.id)
    }

    /// bar 高度对齐系统 inline 导航栏（44pt），使查看器 bar 底边与缩略图页 bar 底边一致
    private static let barHeight: CGFloat = 44
    /// 底部胶片条（DESIGN.md §6.3）：bar 高度、缩略图尺寸
    private static let filmstripHeight: CGFloat = 52
    private static let filmstripItemSize = CGSize(width: 28, height: 40)

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

    private var liveBottomInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
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
        // 连续长条：图片铺满整屏
        if readingOrder == .continuous {
            return true
        }
        // 优先用实时上报的图片顶边（含缩放/平移）；未上报时退回 fit 矩形估算
        if let top = imageTops[currentItem.id] {
            return top < barBottomY - 1
        }
        let image = loadTransitionImage(for: currentItem)
        let fit = fitRect(for: imageSize(of: currentItem, image: image), in: containerSize)
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
        _items = State(initialValue: session.items)
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
                // 竖向查看顺序下竖滑是翻页，不做下拉关闭
                .simultaneousGesture(dismissDrag, including: readingOrder.isVertical ? .subviews : .all)
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
                // 胶片条与顶部 bar 同一套显隐：共读 chromeOpacity（淡出）、滑动式隐藏时向下移出
                filmstrip
                    .compositingGroup()
                    .opacity(chromeOpacity)
                    .offset(y: (presenter.chromeHidden && chromeSlides) ? Self.filmstripHeight + stableSafeBottom : 0)
                    .allowsHitTesting(chromeInteractive)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(
            pendingDeletion?.page != nil ? "删除这个 PDF？" : "删除这张照片？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = pendingDeletion {
                    delete(item)
                }
                pendingDeletion = nil
            }
        } message: {
            Text("将从图库和所有相簿中删除。此操作不可撤销。")
        }
        .alert("新建相簿", isPresented: $showingNewAlbumAlert) {
            TextField("相簿名称", text: $newAlbumName)
            Button("取消", role: .cancel) {}
            Button("存储") { addCurrentToNewAlbum() }
        } message: {
            Text("为此相簿输入一个名称。")
        }
        .fullScreenCover(item: $editingItem) { item in
            PhotoCropView(photoID: item.photoID) {
                reloadItems(of: item.photoID)
            }
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
            } else if let action = env["VIEWER_ACTION"] {
                // VIEWER_ACTION=crop 打开裁剪编辑器；delete 直接删除当前张（跳过确认框），验证删除后的翻页 / 关闭
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if action == "crop" {
                        editingItem = currentItem
                    } else if action == "delete" {
                        delete(currentItem)
                    }
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

    /// 查看顺序（「…」菜单里选，全局记住）
    private var readingOrder: ViewerReadingOrder {
        ViewerReadingOrder(rawValue: readingOrderRaw) ?? .leftToRight
    }

    private var pager: some View {
        Group {
            switch readingOrder {
            case .leftToRight, .rightToLeft:
                horizontalPager
            case .topToBottom:
                verticalPager
            case .continuous:
                continuousPager
            }
        }
        .onChange(of: index) {
            // 拖拽接管时 TabView 的翻页手势被取消，可能瞬时抖动 index 再弹回，
            // 只在正常浏览状态下联动空白格子，避免邻居缩略图闪空白
            guard phase == .presented else { return }
            presenter.setHiddenPhoto(currentItem.photoID)
        }
    }

    /// 从左到右 / 从右到左：系统分页（从右到左 = 整个分页容器按右到左排，下一张在左边）
    private var horizontalPager: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                zoomablePage(item, at: offset)
                    // 页内内容不跟着镜像
                    .environment(\.layoutDirection, .leftToRight)
                    // TabView 的分页容器会给每一页重新注入安全区，页内也必须显式忽略，
                    // 否则页内 fit 布局与过渡层错位，交接瞬间图片会向下跳
                    .ignoresSafeArea()
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, readingOrder == .rightToLeft ? .rightToLeft : .leftToRight)
        // 页面必须真正全屏（刘海、底部指示条区域都可显示内容）
        .ignoresSafeArea()
    }

    /// 从上到下：竖向分页，一屏一张
    private var verticalPager: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    zoomablePage(item, at: offset)
                        .frame(width: containerSize.width, height: containerSize.height)
                        .id(offset)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding(get: { index }, set: { if let new = $0 { index = new } }))
        .ignoresSafeArea()
    }

    /// 连续从上到下：按屏宽竖排成一条、之间无间隙，整条一起缩放
    private var continuousPager: some View {
        ContinuousStripView(
            items: items,
            index: $index,
            box: continuousBox,
            onSingleTap: { setChrome(hidden: !presenter.chromeHidden, slide: imageIntrudesBar) },
            onZoomChanged: { zoomed in
                if zoomed {
                    zoomedPages.insert(currentItem.id)
                } else {
                    zoomedPages.remove(currentItem.id)
                }
                if zoomed, !presenter.chromeHidden {
                    setChrome(hidden: true, slide: false, duration: 0.12)
                }
            },
            onImageReady: { id in
                readyPages.insert(id)
                finishOpenIfReady()
            }
        )
        .ignoresSafeArea()
    }

    private func zoomablePage(_ item: ViewerItem, at offset: Int) -> some View {
        ZoomableImageView(
            item: item,
            isCurrent: offset == index,
            onSingleTap: {
                // 单击：图片侵入 bar 区域时用滑动式（滑开露出图片），
                // 否则（bar 处无图片）用淡入淡出
                setChrome(hidden: !presenter.chromeHidden, slide: imageIntrudesBar)
            },
            onZoomChanged: { zoomed in
                if zoomed {
                    zoomedPages.insert(item.id)
                } else {
                    zoomedPages.remove(item.id)
                }
                // 放大浏览时进入沉浸模式（与原生一致）：快速淡出式隐藏（图片已盖住 bar，
                // 慢慢淡出会显得拖沓）
                if zoomed, offset == index, !presenter.chromeHidden {
                    setChrome(hidden: true, slide: false, duration: 0.12)
                }
            },
            onImageReady: {
                readyPages.insert(item.id)
                finishOpenIfReady()
            },
            onImageTopChanged: { top in
                imageTops[item.id] = top
            }
        )
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
            moreMenu
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

    // MARK: 「…」菜单

    /// 右上角「…」：分享 / 添加到相簿 / 编辑（裁剪）/ 删除；PDF 在最上面显示当前页码
    private var moreMenu: some View {
        Menu {
            if let page = currentItem.page {
                Section {
                    Text("第 \(page + 1) / \(currentItem.pageCount) 页")
                }
            }
            Section {
                Button("分享", systemImage: "square.and.arrow.up") {
                    if let photo = photo(for: currentItem) {
                        PhotoSharing.share([photo])
                    }
                }
                Menu("添加到相簿", systemImage: "rectangle.stack.badge.plus") {
                    ForEach(albums) { album in
                        Button(album.name, systemImage: "rectangle.stack") {
                            if let photo = photo(for: currentItem) {
                                AlbumOperations.add([photo], to: album, in: modelContext)
                                try? modelContext.save()
                            }
                        }
                    }
                    if !albums.isEmpty {
                        Divider()
                    }
                    Button("新建相簿…", systemImage: "plus") {
                        newAlbumName = ""
                        showingNewAlbumAlert = true
                    }
                }
                // PDF 不能裁剪
                if currentItem.page == nil {
                    Button("编辑", systemImage: "crop") {
                        editingItem = currentItem
                    }
                }
            }
            Section {
                Picker(selection: $readingOrderRaw) {
                    ForEach(ViewerReadingOrder.allCases) { order in
                        Label(order.title, systemImage: order.systemImage).tag(order.rawValue)
                    }
                } label: {
                    Label("查看顺序", systemImage: "book")
                }
                .pickerStyle(.menu)
            }
            Section {
                Button("删除", systemImage: "trash", role: .destructive) {
                    pendingDeletion = currentItem
                }
            }
        } label: {
            // 圆形底色 + 三个点（原生相册同款），不用 ellipsis.circle 的描边圆圈
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(.tertiarySystemFill)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    private func photo(for item: ViewerItem) -> Photo? {
        let id = item.photoID
        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func addCurrentToNewAlbum() {
        guard let photo = photo(for: currentItem) else { return }
        let trimmed = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = AlbumOperations.createAlbum(named: trimmed.isEmpty ? "未命名相簿" : trimmed, in: modelContext)
        AlbumOperations.add([photo], to: album, in: modelContext)
        try? modelContext.save()
    }

    /// 删除后停在原位置（即下一张；删的是末尾则前一张）；删光了就原地缩小淡出关闭（格子已不在，不落回）
    private func delete(_ item: ViewerItem) {
        guard let photo = photo(for: item) else { return }
        let remaining = items.filter { $0.photoID != item.photoID }
        let position = items.firstIndex { $0.photoID == item.photoID } ?? index
        AlbumOperations.deletePhotos([photo], in: modelContext)
        try? modelContext.save()
        guard !remaining.isEmpty else {
            beginClose(returnsToGrid: false)
            return
        }
        items = remaining
        index = min(position, remaining.count - 1)
        presenter.setHiddenPhoto(currentItem.photoID)
    }

    /// 编辑（裁剪 / 复原）后：换成新尺寸、新版本号的页（id 变了，翻页器重新加载这一页）
    private func reloadItems(of photoID: UUID) {
        let id = photoID
        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let photo = (try? modelContext.fetch(descriptor))?.first,
              let first = items.firstIndex(where: { $0.photoID == photoID })
        else {
            return
        }
        let count = items[first...].prefix { $0.photoID == photoID }.count
        items.replaceSubrange(first..<(first + count), with: ViewerItem.items(for: photo))
    }

    // MARK: 胶片条

    /// 当前页展开为原始比例（拖动中不展开）
    private var expandedFilmstripID: String? {
        isScrubbing ? nil : currentItem.id
    }

    /// 胶片条一格的排布。普通照片之间 2pt，当前张两侧各再空出 4pt。
    /// 多页 PDF 的各页叠成一组：压在最上面的页完整露出（正在看的 PDF 是当前页，其余 PDF 是首页），
    /// 往左、往右依次一页压一页、每页只露出一截（越远越在下面）；正在看的 PDF 整组两侧空出、与前后照片隔开
    private struct FilmstripSlot {
        var width: CGFloat
        /// 在条里占的宽度（叠放的页小于 width，多出的部分压在靠近顶页的那一格下面）
        var layoutWidth: CGFloat
        /// 叠放的页露出哪一侧：顶页左边的露左侧、右边的露右侧
        var alignment: Alignment
        var leading: CGFloat
        var trailing: CGFloat
        var isStackedPage: Bool
        var zIndex: Double
    }

    private static let filmstripGap: CGFloat = 1
    private static let filmstripCurrentGap: CGFloat = 5
    /// 叠放的 PDF 页露出的宽度
    private static let filmstripStackStep: CGFloat = 9

    private func filmstripSlot(for item: ViewerItem) -> FilmstripSlot {
        let expanded = item.id == expandedFilmstripID
        let itemSize = Self.filmstripItemSize
        let width = expanded
            ? min(max(itemSize.height * item.aspectRatio, itemSize.width), itemSize.height * 1.8)
            : itemSize.width
        guard let page = item.page, item.pageCount > 1 else {
            let gap = expanded ? Self.filmstripCurrentGap : Self.filmstripGap
            return FilmstripSlot(width: width, layoutWidth: width, alignment: .leading, leading: gap, trailing: gap,
                                 isStackedPage: false, zIndex: expanded ? 1 : 0)
        }
        let isCurrentGroup = item.photoID == currentItem.photoID
        let topPage = isCurrentGroup ? (currentItem.page ?? 0) : 0
        let groupGap = isCurrentGroup && !isScrubbing ? Self.filmstripCurrentGap : Self.filmstripGap
        return FilmstripSlot(
            width: width,
            layoutWidth: page == topPage ? width : Self.filmstripStackStep,
            alignment: page < topPage ? .leading : .trailing,
            leading: page == 0 ? groupGap : 0,
            trailing: page == item.pageCount - 1 ? groupGap : 0,
            isStackedPage: true,
            zIndex: -Double(abs(page - topPage)))
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    let slot = filmstripSlot(for: item)
                    FilmstripThumbnail(item: item, size: CGSize(width: slot.width, height: Self.filmstripItemSize.height),
                                       showsEdge: slot.isStackedPage)
                        .frame(width: slot.layoutWidth, alignment: slot.alignment)
                        .contentShape(Rectangle())
                        .onTapGesture { jumpFromFilmstrip(to: item.id) }
                        .id(item.id)
                        .padding(.leading, slot.leading)
                        .padding(.trailing, slot.trailing)
                        .zIndex(slot.zIndex)
                }
            }
            .scrollTargetLayout()
            .animation(.easeOut(duration: 0.2), value: expandedFilmstripID)
        }
        // 首尾两张也能滚到正中。不用 .viewAligned：它按格子左边缘对齐，展开的当前张会偏右；
        // 停下后由 onScrollPhaseChange 把当前张滚回正中
        .contentMargins(.horizontal, containerSize.width / 2, for: .scrollContent)
        .scrollPosition($filmstripPosition, anchor: .center)
        .onScrollPhaseChange { _, newPhase in
            let scrubbing = newPhase == .interacting || newPhase == .decelerating
            guard scrubbing != isScrubbing else { return }
            isScrubbing = scrubbing
            if !scrubbing {
                // 停下后对正当前张（展开后宽度变了）
                centerFilmstrip(animated: true)
            }
        }
        .onChange(of: filmstripPosition.viewID(type: String.self)) { _, id in
            // 只响应用户拖动：程序滚动（翻页联动）不反向改页码
            guard isScrubbing, let id, id != currentItem.id,
                  let target = items.firstIndex(where: { $0.id == id }) else { return }
            index = target
        }
        .onChange(of: index) {
            guard !isScrubbing else { return }
            centerFilmstrip(animated: true)
        }
        .task {
            // LazyHStack 首次定位按估算尺寸算偏移（实测展开的当前张偏右 ~5pt）：布局完成后再对正一次
            centerFilmstrip(animated: false)
            try? await Task.sleep(for: .milliseconds(50))
            centerFilmstrip(animated: false)
        }
        #if DEBUG
        // 调试：FILMSTRIP_JUMP=n 打开 1.5s 后模拟点按胶片条第 n 格（验证翻页器与胶片条联动）
        .task {
            guard let raw = ProcessInfo.processInfo.environment["FILMSTRIP_JUMP"], let target = Int(raw),
                  items.indices.contains(target) else { return }
            try? await Task.sleep(for: .seconds(1.5))
            jumpFromFilmstrip(to: items[target].id)
        }
        #endif
        // 从右到左时胶片条也从右往左排（下一张在左边）
        .environment(\.layoutDirection, readingOrder == .rightToLeft ? .rightToLeft : .leftToRight)
        .frame(height: Self.filmstripHeight)
        .padding(.bottom, stableSafeBottom)
        .background {
            // 底色规则同顶部 bar
            ZStack {
                Color(.systemBackground)
                Color.black.opacity(barOverImage ? 0 : immersiveAmount)
            }
        }
    }

    private func centerFilmstrip(animated: Bool) {
        let id = currentItem.id
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { filmstripPosition.scrollTo(id: id, anchor: .center) }
        } else {
            filmstripPosition.scrollTo(id: id, anchor: .center)
        }
    }

    private func jumpFromFilmstrip(to itemID: String) {
        guard let target = items.firstIndex(where: { $0.id == itemID }) else { return }
        index = target
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

    private var currentItem: ViewerItem {
        items[max(0, min(index, items.count - 1))]
    }

    private func beginOpen() {
        // 打开时状态栏可见，捕获稳定的状态栏高度供 bar 布局使用
        stableSafeTop = liveStatusBarHeight
        stableSafeBottom = liveBottomInset
        let item = currentItem
        let image = loadTransitionImage(for: item)
        transitionImage = image
        let target = landingRect(for: item, image: image)
        // 预热大图（翻页器当前页也在同步加载，就绪后过渡层才让位）
        Task { _ = await item.image(.large) }

        let screen = CGRect(origin: .zero, size: containerSize)
        let visible = gridVisibleRect
        if let source = session.sourceFrame(item.photoID), source.intersects(visible) {
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
        guard phase == .opening, openAnimationDone, readyPages.contains(currentItem.id) else { return }
        phase = .presented
    }

    // MARK: 关闭

    /// returnsToGrid=false：不落回格子、原地缩小淡出（刚删除的照片，格子已不在）
    private func beginClose(returnsToGrid: Bool = true) {
        guard phase == .presented || phase == .dragging else { return }
        // 拖拽发起的关闭以拖拽开始时锁定的照片为准，不受 index 瞬时抖动影响
        let item: ViewerItem
        if phase == .dragging, let dragID = draggingItemID,
           let dragged = items.first(where: { $0.id == dragID }) {
            item = dragged
        } else {
            item = currentItem
        }
        if phase == .presented {
            // 从静止状态关闭：过渡层先在原位接管画面（与翻页器逐像素重合，切换无缝）
            let image = loadTransitionImage(for: item)
            transitionImage = image
            transitionRect = readingOrder == .continuous
                ? continuousBox.frameOfItem?(item.id) ?? landingRect(for: item, image: image)
                : fitRect(for: imageSize(of: item, image: image), in: containerSize)
            transitionOpacity = 1
        }
        phase = .closing

        let screen = CGRect(origin: .zero, size: containerSize)
        let visible = gridVisibleRect
        maskRect = screen
        if returnsToGrid, let target = session.sourceFrame(item.photoID), target.intersects(visible) {
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
                            if let dragID = draggingItemID,
                               let draggedIndex = items.firstIndex(where: { $0.id == dragID }) {
                                index = draggedIndex
                            }
                            phase = .presented
                            presenter.setHiddenPhoto(currentItem.photoID)
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
        let item = currentItem
        let image = loadTransitionImage(for: item)
        transitionImage = image
        draggingItemID = item.id
        presenter.setHiddenPhoto(item.photoID)
        chromeSuppressed = true
        dragFitRect = fitRect(for: imageSize(of: item, image: image), in: containerSize)
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

    private func loadTransitionImage(for item: ViewerItem) -> UIImage? {
        if let cached = item.cachedImage(.large) ?? item.cachedImage(.small) {
            return cached
        }
        // 图片 / PDF 首页：格子用的缩略图；PDF 其他页：胶片条的小图
        return (item.page ?? 0) == 0
            ? ImageStore.shared.loadThumbnail(photoID: item.photoID, kind: .small)
            : item.cachedImage(.tiny)
    }

    private func imageSize(of item: ViewerItem, image: UIImage?) -> CGSize {
        if let image {
            return image.size
        }
        if item.aspectRatio > 0 {
            return CGSize(width: 1000 * item.aspectRatio, height: 1000)
        }
        return containerSize
    }

    /// 打开后图片在屏幕上的位置：连续长条里按屏宽排、其余为 fit
    private func landingRect(for item: ViewerItem, image: UIImage?) -> CGRect {
        guard readingOrder == .continuous, let position = items.firstIndex(of: item) else {
            return fitRect(for: imageSize(of: item, image: image), in: containerSize)
        }
        return ContinuousStripView.landingRect(items: items, index: position, container: containerSize)
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

/// 胶片条里的一格（宽度由排布决定：平时窄条，当前页展开为原始比例）
private struct FilmstripThumbnail: View {
    let item: ViewerItem
    let size: CGSize
    /// 叠放的 PDF 页：加一道阴影，看得出页与页的边界
    let showsEdge: Bool

    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .shadow(color: .black.opacity(showsEdge ? 0.35 : 0), radius: 1.5, x: 0.5)
            .task(id: item.id) {
                if let cached = item.cachedImage(.tiny) ?? item.cachedImage(.small) {
                    image = cached
                    return
                }
                image = await item.image(.tiny)
            }
    }
}

/// 查看顺序（「…」→ 查看顺序）
enum ViewerReadingOrder: String, CaseIterable, Identifiable {
    /// 下一张从右边往左滑进来
    case leftToRight
    /// 下一张从左边往右滑进来（漫画）
    case rightToLeft
    /// 竖向翻页，一屏一张
    case topToBottom
    /// 竖向连续、图片之间无间隙（像 PDF 连续滚动）
    case continuous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftToRight: "从左到右"
        case .rightToLeft: "从右到左"
        case .topToBottom: "从上到下"
        case .continuous: "连续从上到下"
        }
    }

    var systemImage: String {
        switch self {
        case .leftToRight: "arrow.right"
        case .rightToLeft: "arrow.left"
        case .topToBottom: "arrow.down"
        case .continuous: "arrow.down.to.line.compact"
        }
    }

    var isVertical: Bool {
        self == .topToBottom || self == .continuous
    }
}
