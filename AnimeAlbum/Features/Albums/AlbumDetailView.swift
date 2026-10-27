import PhotosUI
import SwiftData
import SwiftUI

struct AlbumDetailView: View {
    let album: Album

    @Environment(\.modelContext) private var modelContext
    @Environment(ViewerPresenter.self) private var viewerPresenter
    @Environment(SelectionBarPresenter.self) private var selectionBarPresenter
    /// RootView 启动后在屏幕外预搭的那一份：不跑任何任务（调试的自动导入等会执行两遍）
    @Environment(\.isPrewarmCopy) private var isPrewarmCopy
    @State private var showingPicker = false
    // 相簿里直接导入（系统相册 / 文件）：先进图库（按内容哈希去重），再加入本相簿
    @State private var importer = PhotoImporter()
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var frameBox = GridFrameBox()
    @State private var navItemsMotion = NavBarItemsMotion()

    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var photosPendingRemoval: [Photo] = []
    @State private var photosPendingNewAlbum: [Photo] = []
    @State private var showingNewAlbumAlert = false
    @State private var newAlbumName = ""

    /// 相簿里的照片：数据库按 sortIndex 排好序取出、顺带预取照片（不在内存里逐条比较排序 ——
    /// 1500 张的相簿每次刷新 110～230ms，第一次进相簿时刷新好几次，推入动画被吃掉，采样实测）
    @Query private var entries: [AlbumEntry]

    init(album: Album) {
        self.album = album
        let albumID = album.id
        var descriptor = FetchDescriptor<AlbumEntry>(
            predicate: #Predicate { $0.album?.id == albumID },
            sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.relationshipKeyPathsForPrefetching = [\.photo]
        _entries = Query(descriptor)
    }

    /// 推入时先不取数据：SwiftUI 推入前会同步算一遍目标页，大相簿的查询（1500 张约 120ms）全压在推入动画开始前，
    /// 刚启动时第一次进相簿推入动画被吃掉（用户反馈）。页面出现后的下一轮再取 —— 推入动画由渲染进程驱动，
    /// 主线程忙也照样走，照片在滑入途中出现
    @State private var showsContent = false

    private var photos: [Photo] {
        showsContent ? entries.compactMap(\.photo) : []
    }

    private var selectedPhotos: [Photo] {
        photos.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        #if DEBUG
        let _ = isPrewarmCopy ? () : Self.debugStall(at: "body")
        #endif
        Group {
            if !showsContent {
                Color(.systemBackground)
            } else if photos.isEmpty {
                ContentUnavailableView {
                    Label("相簿是空的", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("从图库挑选照片放进这个相簿。")
                } actions: {
                    Menu {
                        addMenuItems
                    } label: {
                        Text("添加照片")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            } else {
                #if DEBUG
                let _ = isPrewarmCopy ? () : Self.debugStall(at: "content")
                #endif
                // UICollectionView 桥接：拖拽排序 + 捏合缩放列数 + Context Menu + 选择模式（DESIGN.md §6.4）
                ReorderablePhotoGrid(
                    photos: photos,
                    onTap: { index in
                        // PDF 也在查看器里按页看（见 ViewerItem）
                        let box = frameBox
                        viewerPresenter.present(
                            photos: photos, index: index,
                            sourceFrame: { box.lookup?($0) },
                            sourceVisibleRect: { box.visibleRect?() })
                    },
                    onMove: { photoID, destination in
                        AlbumOperations.move(photoID: photoID, toIndex: destination, in: album, context: modelContext)
                    },
                    contextMenu: { cellContextMenu(for: $0) },
                    frameBox: frameBox,
                    viewerPresenter: viewerPresenter,
                    isSelecting: isSelecting,
                    selectedIDs: $selectedIDs
                )
            }
        }
        #if DEBUG
        .background {
            if !isPrewarmCopy {
                PushProbe().frame(width: 0, height: 0)
                if ProcessInfo.processInfo.environment["PUSH_STALL_AT"] == "draw" {
                    DebugStallDrawView().frame(width: 10, height: 10)
                }
            }
        }
        #endif
        // 导航栏右侧按钮随这一页滑动（NavBarItemsMotion）
        .background { NavBarItemsMotion.PageProbe(motion: navItemsMotion).frame(width: 0, height: 0) }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        // 选择中不能返回（底部栏属于这一页），与原生一致：先「取消」再离开
        .navigationBarBackButtonHidden(isSelecting)
        .toolbar { toolbarContent }
        .onAppear {
            guard !showsContent else { return }
            #if DEBUG
            Self.debugStall(at: "appear")
            #endif
            DispatchQueue.main.async { showsContent = true }
        }
        .onChange(of: selectedIDs) {
            selectionBarPresenter.update(photos: selectedPhotos)
        }
        .onChange(of: photos.isEmpty) { _, isEmpty in
            if isEmpty, isSelecting {
                exitSelectionMode()
            }
        }
        .onDisappear {
            if isSelecting {
                exitSelectionMode()
            }
        }
        .sheet(isPresented: $showingPicker) {
            AlbumPhotoPickerSheet(album: album)
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $pickerItems, matching: .any(of: [.images, .videos, .livePhotos]))
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { addImported(await importer.importPickerItems(items, context: modelContext)) }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: PhotoImporter.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { addImported(await importer.importFiles(at: urls, context: modelContext)) }
            }
        }
        .overlay(alignment: .bottom) { ImportStatusOverlay(importer: importer) }
        // 从其他 App 拖图片进来：先进图库（去重）再加入本相簿
        .onDrop(of: PhotoImporter.importableTypes, isTargeted: nil) { providers in
            Task { addImported(await importer.importItemProviders(providers, context: modelContext)) }
            return true
        }
        .confirmationDialog(
            "\(photosPendingRemoval.count) 张照片",
            isPresented: removalDialogPresented,
            titleVisibility: .visible
        ) {
            Button("从相簿中移除", role: .destructive) { removePendingPhotos() }
            Button("从图库删除", role: .destructive) { deletePendingPhotos() }
        } message: {
            Text("从相簿中移除后照片仍保留在图库；从图库删除会同时将其移出所有相簿，且不可撤销。")
        }
        .alert("新建相簿", isPresented: $showingNewAlbumAlert) {
            TextField("相簿名称", text: $newAlbumName)
            Button("取消", role: .cancel) { photosPendingNewAlbum = [] }
            Button("存储") { commitNewAlbum() }
        } message: {
            Text("为此相簿输入一个名称。")
        }
        .task {
            guard !isPrewarmCopy else { return }
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            // 调试辅助：OPEN_PICKER=1 进入相簿后自动弹出「添加照片」选择器
            if env["OPEN_PICKER"] == "1" {
                try? await Task.sleep(for: .seconds(0.6))
                showingPicker = true
            }
            // ALBUM_IMPORT_FILES=路径1,路径2 进入相簿后直接导入这些文件（走与「从文件导入」相同的路径）
            if let raw = env["ALBUM_IMPORT_FILES"] {
                try? await Task.sleep(for: .seconds(0.6))
                let urls = raw.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                addImported(await importer.importFiles(at: urls, context: modelContext))
            }
            // ALBUM_SELECT=n 进入相簿后自动进入选择模式并预选前 n 张
            if let raw = env["ALBUM_SELECT"], let count = Int(raw) {
                try? await Task.sleep(for: .seconds(0.6))
                enterSelectionMode()
                selectedIDs = Set(photos.prefix(count).map(\.id))
            }
            #endif
        }
    }

    #if DEBUG
    /// PUSH_STALL=毫秒 PUSH_STALL_AT=body|appear：第一次进相簿时在指定位置卡住主线程（模拟真机首次搭页慢）
    private static var stalled = false
    fileprivate static func debugStall(at site: String) {
        let env = ProcessInfo.processInfo.environment
        guard !stalled, let raw = env["PUSH_STALL"], let ms = Double(raw), env["PUSH_STALL_AT", default: "body"] == site else { return }
        stalled = true
        print("PUSH_STALL \(site) \(ms)ms")
        Thread.sleep(forTimeInterval: ms / 1000)
    }
    #endif

    /// 长按菜单：设为封面 / 从相簿中移除
    private func cellContextMenu(for photoID: UUID) -> [GridMenuItem] {
        [
            GridMenuItem(title: "分享", systemImage: "square.and.arrow.up") {
                if let photo = photos.first(where: { $0.id == photoID }) {
                    PhotoSharing.share([photo])
                }
            },
            GridMenuItem(title: "设为封面", systemImage: "photo.badge.checkmark") {
                album.coverPhotoID = photoID
                try? modelContext.save()
            },
            GridMenuItem(title: "从相簿中移除", systemImage: "rectangle.stack.badge.minus", isDestructive: true) {
                if let photo = photos.first(where: { $0.id == photoID }) {
                    AlbumOperations.remove(photo, from: album, in: modelContext)
                }
            },
        ]
    }

    // MARK: - 工具栏

    /// 两种模式各用一套独立的工具栏项、整组替换（原因见 LibraryView.toolbarContent）
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("取消") { exitSelectionMode() }
                    .background { NavBarItemsMotion.ItemProbe(motion: navItemsMotion) }
            }
        } else {
            // 两个按钮合成一个导航栏项：分成两项时，推入过渡中系统只显示第一项、第二项等滑入结束才冒出来（iOS 18 实测，
            // 与按钮种类无关）。间距 19 = 系统两个独立项的间距。整项随页面滑动（NavBarItemsMotion）
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 19) {
                    // 按查询结果判断、不看 photos：推入期间 photos 还是空的（showsContent）
                    if !entries.isEmpty {
                        Button("选择") { enterSelectionMode() }
                    }
                    Menu {
                        addMenuItems
                    } label: {
                        Label("添加照片", systemImage: "plus")
                    }
                }
                .background { NavBarItemsMotion.ItemProbe(motion: navItemsMotion) }
            }
        }
    }

    // MARK: - 添加照片

    @ViewBuilder
    private var addMenuItems: some View {
        Button("从图库选择", systemImage: "photo.on.rectangle.angled") {
            showingPicker = true
        }
        Button("从照片图库导入", systemImage: "photo.badge.plus") {
            showingPhotosPicker = true
        }
        Button("从文件导入", systemImage: "folder") {
            showingFileImporter = true
        }
    }

    /// 导入结果（新导入的 + 图库中已有的重复项）一并加入本相簿；已在相簿里的跳过
    private func addImported(_ result: PhotoImporter.ImportResult) {
        let added = AlbumOperations.add(result.photos, to: album, in: modelContext)
        try? modelContext.save()
        var parts = ["已添加 \(added) 张到相簿"]
        if result.duplicates > 0 {
            parts.append("其中 \(result.duplicates) 张图库中已有")
        }
        if result.failed > 0 {
            parts.append("失败 \(result.failed) 张")
        }
        importer.summary = parts.joined(separator: "，")
    }

    // MARK: - 选择模式

    private func enterSelectionMode() {
        isSelecting = true
        // 底部栏由 RootView 顶层渲染（覆盖 Tab 栏），「添加到相簿」菜单里排除当前相簿
        selectionBarPresenter.beginPhotos(
            excludingAlbum: album.id,
            onDelete: { [selectionBarPresenter] in
                photosPendingRemoval = selectionBarPresenter.session?.photos ?? []
            },
            onNewAlbum: { promptNewAlbum(with: $0) },
            onAdded: { exitSelectionMode() })
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIDs = []
        selectionBarPresenter.end()
    }

    private var removalDialogPresented: Binding<Bool> {
        Binding(
            get: { !photosPendingRemoval.isEmpty },
            set: { if !$0 { photosPendingRemoval = [] } }
        )
    }

    private func removePendingPhotos() {
        for photo in photosPendingRemoval {
            AlbumOperations.remove(photo, from: album, in: modelContext)
        }
        photosPendingRemoval = []
        exitSelectionMode()
    }

    private func deletePendingPhotos() {
        AlbumOperations.deletePhotos(photosPendingRemoval, in: modelContext)
        photosPendingRemoval = []
        exitSelectionMode()
    }

    private func promptNewAlbum(with photos: [Photo]) {
        photosPendingNewAlbum = photos
        newAlbumName = ""
        showingNewAlbumAlert = true
    }

    private func commitNewAlbum() {
        let trimmed = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAlbum = AlbumOperations.createAlbum(named: trimmed.isEmpty ? "未命名相簿" : trimmed, in: modelContext)
        AlbumOperations.add(photosPendingNewAlbum, to: newAlbum, in: modelContext)
        photosPendingNewAlbum = []
        exitSelectionMode()
    }
}

#if DEBUG
/// PUSH_STALL_AT=draw：在 CA 提交的绘制阶段卡住（模拟真机提交时解码大量图片）
private struct DebugStallDrawView: UIViewRepresentable {
    final class StallView: UIView {
        override func draw(_ rect: CGRect) {
            AlbumDetailView.debugStall(at: "draw")
        }
    }
    func makeUIView(context: Context) -> StallView {
        let view = StallView()
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ uiView: StallView, context: Context) {}
}
#endif
