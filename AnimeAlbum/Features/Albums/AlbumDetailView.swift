import PhotosUI
import SwiftData
import SwiftUI

/// 相簿详情：显示选项（全局或各页各自，见 PrivacyLock.filter(for:)）变了就按新条件重建下面那页的查询
struct AlbumDetailScreen: View {
    let album: Album
    @Environment(PrivacyLock.self) private var privacyLock

    var body: some View {
        // 隐藏的相簿（默认设置下）：相簿的隐藏作用于其中全部照片 —— 看得到这个相簿就看得到里面全部照片，没有显示选项
        if album.isHidden, !privacyLock.hiddenAlbumsHidePhotos {
            AlbumDetailView(album: album, filter: .constant(.all), filterAdjustable: false)
        } else {
            AlbumDetailView(album: album, filter: privacyLock.filterBinding(for: .album(album.id)))
        }
    }
}

struct AlbumDetailView: View {
    let album: Album
    @Binding var filter: HiddenFilter
    /// 有没有显示选项（隐藏相簿里照片全部显示时没有）
    var filterAdjustable = true

    @Environment(\.modelContext) private var modelContext
    @Environment(ViewerPresenter.self) private var viewerPresenter
    @Environment(SelectionBarPresenter.self) private var selectionBarPresenter
    /// RootView 启动后在屏幕外预搭的那一份：不跑任何任务（调试的自动导入等会执行两遍）
    @Environment(\.isPrewarmCopy) private var isPrewarmCopy
    @Environment(PrivacyLock.self) private var privacyLock
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

    init(album: Album, filter: Binding<HiddenFilter>, filterAdjustable: Bool = true) {
        self.album = album
        _filter = filter
        self.filterAdjustable = filterAdjustable
        let albumID = album.id
        let predicate: Predicate<AlbumEntry>
        switch filter.wrappedValue {
        case .visible:
            predicate = #Predicate { $0.album?.id == albumID && $0.photo?.isHidden == false }
        case .hiddenOnly:
            predicate = #Predicate { $0.album?.id == albumID && $0.photo?.isHidden == true }
        case .all:
            predicate = #Predicate { $0.album?.id == albumID }
        }
        var descriptor = FetchDescriptor<AlbumEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.relationshipKeyPathsForPrefetching = [\.photo]
        _entries = Query(descriptor)
    }

    /// 推入前就把宫格搭好、第一帧就在：曾经推入时先不取数据（以为主线程忙会吃掉推入动画 —— 已证伪，见 CLAUDE.md），
    /// 结果滑入的头几帧是空白页、宫格随后才闪出来（用户反馈，录屏实测）
    private var photos: [Photo] {
        entries.compactMap(\.photo)
    }

    private var selectedPhotos: [Photo] {
        photos.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        #if DEBUG
        let _ = isPrewarmCopy ? () : Self.debugStall(at: "body")
        #endif
        content
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
        // 导航栏右侧按钮随这一页滑动（NavBarItemsMotion）；查看器打开时导航栏配色（ViewerStatusBarHint）
        .background {
            NavBarItemsMotion.PageProbe(motion: navItemsMotion).frame(width: 0, height: 0)
            ViewerStatusBarHint()
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        // 选择中不能返回（底部栏属于这一页），与原生一致：先「取消」再离开
        .navigationBarBackButtonHidden(isSelecting)
        .toolbar { toolbarContent }
        #if DEBUG
        .onAppear {
            Self.debugStall(at: "appear")
        }
        #endif
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
        .photosPicker(isPresented: $showingPhotosPicker, selection: $pickerItems,
                      matching: .any(of: [.images, .videos, .livePhotos]), photoLibrary: .shared())
        .offersOriginalDeletion(importer: importer)
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

    @ViewBuilder
    private var content: some View {
        if photos.isEmpty, filter == .hiddenOnly {
            ContentUnavailableView("没有隐藏的照片", systemImage: "eye.slash",
                                   description: Text("这个相簿里没有隐藏的照片。"))
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
                        sourceVisibleRect: { box.visibleRect?() },
                        hiddenFilter: filter)
                },
                onMove: { photoID, destination in
                    AlbumOperations.move(photoID: photoID, toIndex: destination, in: album, context: modelContext)
                },
                contextMenu: { cellContextMenu(for: $0) },
                frameBox: frameBox,
                viewerPresenter: viewerPresenter,
                isSelecting: isSelecting,
                selectedIDs: $selectedIDs,
                marksHidden: filter == .all,
                sidebarAlbums: { AlbumOperations.sidebarAlbums(in: modelContext, filter: privacyLock.filter(for: .albums)) },
                canAddToAlbum: { photoID, albumID in
                    // 自己所在的相簿、已经在里面的相簿：不能加
                    albumID != album.id && !AlbumOperations.contains(photoID: photoID, albumID: albumID, in: modelContext)
                },
                onAddToAlbum: { photoID, albumID in
                    AlbumOperations.add(photoID: photoID, toAlbumID: albumID, in: modelContext)
                },
                contentKey: filter
            )
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
            GridMenuItem(title: "添加到相簿", systemImage: "rectangle.stack.badge.plus",
                         children: addToAlbumItems(for: photoID)),
            GridMenuItem(title: "设为封面", systemImage: "photo.badge.checkmark") {
                album.coverPhotoID = photoID
                try? modelContext.save()
            },
            GridMenuItem(title: hiddenTitle(photoID), systemImage: hiddenImage(photoID),
                         action: {
                             if let photo = photos.first(where: { $0.id == photoID }) {
                                 photo.isHidden.toggle()
                                 try? modelContext.save()
                             }
                         },
                         removesPhoto: hidingRemoves(photoID)),
            GridMenuItem(title: "从相簿中移除", systemImage: "rectangle.stack.badge.minus", isDestructive: true) {
                if let photo = photos.first(where: { $0.id == photoID }) {
                    AlbumOperations.remove(photo, from: album, in: modelContext)
                }
            },
        ]
    }

    /// 「添加到相簿」子菜单：其他相簿（隐藏的相簿只在有页面显示隐藏内容时列出）+ 新建
    private func addToAlbumItems(for photoID: UUID) -> [GridMenuItem] {
        guard let photo = photos.first(where: { $0.id == photoID }) else { return [] }
        let others = ((try? modelContext.fetch(FetchDescriptor<Album>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
            .filter { $0.id != album.id && (!$0.isHidden || privacyLock.showsHiddenAnywhere) }
        let albumItems = others.map { target in
            GridMenuItem(title: target.name, systemImage: "rectangle.stack") {
                AlbumOperations.add([photo], to: target, in: modelContext)
                try? modelContext.save()
            }
        }
        let newAlbum = GridMenuItem(title: "新建相簿…", systemImage: "plus") {
            promptNewAlbum(with: [photo])
        }
        return albumItems + [newAlbum]
    }

    /// 切换隐藏后这张是否不再符合当前显示选项（从这一页消失）
    private func hidingRemoves(_ photoID: UUID) -> Bool {
        guard let photo = photos.first(where: { $0.id == photoID }) else { return false }
        return !filter.includes(isHidden: !photo.isHidden)
    }

    private func hiddenTitle(_ photoID: UUID) -> String {
        photos.first { $0.id == photoID }?.isHidden == true ? "取消隐藏" : "隐藏"
    }

    private func hiddenImage(_ photoID: UUID) -> String {
        photos.first { $0.id == photoID }?.isHidden == true ? "eye" : "eye.slash"
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
                    // 按查询结果判断
                    if !entries.isEmpty {
                        Button("选择") { enterSelectionMode() }
                    }
                    // 添加照片、显示选项都在「…」里
                    PageMoreMenu(filter: $filter, showsFilter: filterAdjustable) {
                        Menu("添加照片", systemImage: "plus") {
                            addMenuItems
                        }
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
            onAdded: { exitSelectionMode() },
            onToggleHidden: { [selectionBarPresenter] in
                // 选中的全部已隐藏 → 都取消隐藏；否则都隐藏
                let selected = selectionBarPresenter.session?.photos ?? []
                let hide = !selected.allSatisfy(\.isHidden)
                for photo in selected {
                    photo.isHidden = hide
                }
                try? modelContext.save()
                exitSelectionMode()
            })
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
