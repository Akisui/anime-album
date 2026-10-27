import PhotosUI
import SwiftData
import SwiftUI

/// 图库：显示选项（隐藏照片）放在这一层，变了就按新条件重建下面那页的查询
struct LibraryView: View {
    @State private var filter: HiddenFilter = .visible

    var body: some View {
        LibraryPage(filter: $filter)
    }
}

private struct LibraryPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ViewerPresenter.self) private var viewerPresenter
    @Environment(SelectionBarPresenter.self) private var selectionBarPresenter
    @Environment(PrivacyLock.self) private var privacyLock
    @Binding var filter: HiddenFilter
    @Query private var photos: [Photo]

    init(filter: Binding<HiddenFilter>) {
        _filter = filter
        var predicate: Predicate<Photo>?
        switch filter.wrappedValue {
        case .visible: predicate = #Predicate { $0.isHidden == false }
        case .hiddenOnly: predicate = #Predicate { $0.isHidden == true }
        case .all: predicate = nil
        }
        _photos = Query(filter: predicate, sort: \Photo.createdAt)
    }

    @State private var importer = PhotoImporter()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var frameBox = GridFrameBox()

    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var photosPendingDeletion: [Photo] = []
    @State private var photosPendingNewAlbum: [Photo] = []
    @State private var showingNewAlbumAlert = false
    @State private var newAlbumName = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("图库")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .overlay(alignment: .bottom) { ImportStatusOverlay(importer: importer) }
                // 从其他 App 拖图片进来（iPad 分屏 / 台前调度）
                .onDrop(of: PhotoImporter.importableTypes, isTargeted: nil) { providers in
                    Task { await importer.importItemProviders(providers, context: modelContext) }
                    return true
                }
                .onChange(of: selectedIDs) {
                    selectionBarPresenter.update(photos: selectedPhotos)
                }
                .resetsHiddenFilter($filter)
        }
        .task {
            #if DEBUG
            // 调试辅助：OPEN_VIEWER=1 自动打开查看器（最后一张）；OPEN_INDEX=n 打开指定序号
            // （可指向被 bar 半遮挡的格子，验证过渡裁切），方便自动化截图
            // SCROLL_TOP=1（滚到顶部）、AUTO_ZOOM 由网格自己处理，见 ReorderablePhotoGrid
            let env = ProcessInfo.processInfo.environment
            // AUTO_SELECT=1 自动进入选择模式，验证 Tab 栏 ↔ 选择栏原位替换（网格不位移）；
            // AUTO_CYCLES=n 自动进出选择模式 n 轮（间隔 1.2s），验证反复切换不产生位移
            if let raw = env["AUTO_CYCLES"], let cycles = Int(raw) {
                for _ in 0..<cycles {
                    try? await Task.sleep(for: .seconds(1.2))
                    toggleSelectionMode()
                    try? await Task.sleep(for: .seconds(1.2))
                    toggleSelectionMode()
                }
            } else if env["AUTO_SELECT"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                toggleSelectionMode()
            }
            // OPEN_PDF=1 打开图库里第一个 PDF（配合 SEED_PDF=1）；PDF_PAGE=n 打开到第 n 页（从 0 起）
            if env["OPEN_PDF"] == "1", let index = photos.firstIndex(where: \.isPDF) {
                try? await Task.sleep(for: .seconds(0.5))
                openViewer(at: index, page: env["PDF_PAGE"].flatMap(Int.init) ?? 0)
            }
            if let raw = env["OPEN_INDEX"], let target = Int(raw), photos.indices.contains(target) {
                try? await Task.sleep(for: .seconds(0.5))
                openViewer(at: target)
            } else if env["OPEN_VIEWER"] == "1", !photos.isEmpty {
                try? await Task.sleep(for: .seconds(0.5))
                openViewer(at: photos.count - 1)
            }
            #endif
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $pickerItems, matching: .any(of: [.images, .videos, .livePhotos]))
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: PhotoImporter.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await importer.importFiles(at: urls, context: modelContext) }
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await importer.importPickerItems(items, context: modelContext) }
        }
        .confirmationDialog(
            "删除 \(photosPendingDeletion.count) 张照片？",
            isPresented: deleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deletePendingPhotos() }
        } message: {
            Text("照片将从图库和所有相簿中删除。此操作不可撤销。")
        }
        .alert("新建相簿", isPresented: $showingNewAlbumAlert) {
            TextField("相簿名称", text: $newAlbumName)
            Button("取消", role: .cancel) { photosPendingNewAlbum = [] }
            Button("存储") { commitNewAlbum() }
        } message: {
            Text("为此相簿输入一个名称。")
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if photos.isEmpty, filter == .hiddenOnly {
            ContentUnavailableView("没有隐藏的照片", systemImage: "eye.slash",
                                   description: Text("长按照片或在查看器的「…」里选「隐藏」。"))
        } else if photos.isEmpty {
            ContentUnavailableView {
                Label("没有照片", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("从照片图库或文件导入角色图片，开始你的收藏。")
            } actions: {
                Menu {
                    importMenuItems
                } label: {
                    Text("导入照片")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        } else {
            // UICollectionView 网格（与相簿详情共用）：捏合换列逐格插值、以手指下的照片为焦点；
            // 选择模式点选 + 滑动连选；底部锚定（进入定位到最新，导入时贴住底部）
            ReorderablePhotoGrid(
                photos: photos,
                onTap: { openViewer(at: $0) },
                contextMenu: { cellContextMenu(for: $0) },
                frameBox: frameBox,
                // 照片在查看器中时格子留空，关闭动画结束才恢复（原生同款逻辑）
                viewerPresenter: viewerPresenter,
                isSelecting: isSelecting,
                selectedIDs: $selectedIDs,
                allowsReordering: false,
                anchorsToBottom: true,
                marksHidden: filter == .all
            )
            // 照片滚到导航栏 / Tab 栏下方（材质透出内容）；UIKit 按 adjustedContentInset 让出首末行
            .ignoresSafeArea()
            // UIKit 网格不会被 SwiftUI 识别为这一页的滚动视图，bar 不会自动切换到材质背景 ——
            // 显式常驻材质，否则照片滚到透明 bar 下面时标题 / Tab 图标直接压在照片上
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        }
    }

    /// 长按菜单：添加到相簿（现有相簿 + 新建）/ 删除
    private func cellContextMenu(for photoID: UUID) -> [GridMenuItem] {
        guard let photo = photos.first(where: { $0.id == photoID }) else { return [] }
        let albums = ((try? modelContext.fetch(FetchDescriptor<Album>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
            .filter { !$0.isHidden || privacyLock.isHiddenUnlocked }
        let albumItems = albums.map { album in
            GridMenuItem(title: album.name, systemImage: "rectangle.stack") {
                AlbumOperations.add([photo], to: album, in: modelContext)
                try? modelContext.save()
            }
        }
        let newAlbum = GridMenuItem(title: "新建相簿…", systemImage: "plus") {
            promptNewAlbum(with: [photo])
        }
        return [
            GridMenuItem(title: "分享", systemImage: "square.and.arrow.up") {
                PhotoSharing.share([photo])
            },
            GridMenuItem(title: "添加到相簿", systemImage: "rectangle.stack.badge.plus",
                         children: albumItems + [newAlbum]),
            GridMenuItem(title: photo.isHidden ? "取消隐藏" : "隐藏",
                         systemImage: photo.isHidden ? "eye" : "eye.slash") {
                photo.isHidden.toggle()
                try? modelContext.save()
            },
            GridMenuItem(title: "删除", systemImage: "trash", isDestructive: true) {
                photosPendingDeletion = [photo]
            },
        ]
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 两种模式各用一套独立的工具栏项、整组替换。不要在同一组里「改按钮文字 + 删掉 +」：
        // 点按「选择」时按钮正处于按下态，导航栏只换文字不重排，「取消」会停在原「选择」的位置，
        // 直到下一次刷新（如点选照片）才跳到最右
        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                // 退出选择、不做任何操作（与原生相册一致）
                Button("取消") {
                    toggleSelectionMode()
                }
            }
        } else {
            // 右上角只放「选择」和「…」（导入、显示选项都在「…」里）
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 19) {
                    if !photos.isEmpty {
                        Button("选择") {
                            toggleSelectionMode()
                        }
                    }
                    PageMoreMenu(filter: $filter) {
                        importMenuItems
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var importMenuItems: some View {
        Button("从照片图库导入", systemImage: "photo.on.rectangle") {
            showingPhotosPicker = true
        }
        Button("从文件导入", systemImage: "folder") {
            showingFileImporter = true
        }
    }


    // MARK: - 交互

    private var selectedPhotos: [Photo] {
        photos.filter { selectedIDs.contains($0.id) }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { !photosPendingDeletion.isEmpty },
            set: { if !$0 { photosPendingDeletion = [] } }
        )
    }

    /// PDF 也在查看器里看：按页展开成一张张图片（见 ViewerItem）
    private func openViewer(at index: Int, page: Int = 0) {
        guard photos.indices.contains(index) else { return }
        let box = frameBox
        viewerPresenter.present(
            photos: photos, index: index, page: page,
            sourceFrame: { box.lookup?($0) },
            sourceVisibleRect: { box.visibleRect?() },
            hiddenFilter: filter)
    }

    private func toggleSelectionMode() {
        if isSelecting {
            exitSelectionMode()
        } else {
            isSelecting = true
            // 底部选择栏由 RootView 顶层渲染（覆盖 Tab 栏、安全区零变化），这里只驱动状态
            selectionBarPresenter.beginPhotos(
                onDelete: { [selectionBarPresenter] in photosPendingDeletion = selectionBarPresenter.session?.photos ?? [] },
                onNewAlbum: { promptNewAlbum(with: $0) },
                onAdded: { exitSelectionMode() },
                onToggleHidden: { [selectionBarPresenter] in
                    toggleHidden(selectionBarPresenter.session?.photos ?? [])
                })
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIDs = []
        selectionBarPresenter.end()
    }

    /// 选中的全部已隐藏 → 都取消隐藏；否则都隐藏
    private func toggleHidden(_ photos: [Photo]) {
        let hide = !photos.allSatisfy(\.isHidden)
        for photo in photos {
            photo.isHidden = hide
        }
        try? modelContext.save()
        exitSelectionMode()
    }

    private func deletePendingPhotos() {
        let deleting = photosPendingDeletion
        photosPendingDeletion = []
        AlbumOperations.deletePhotos(deleting, in: modelContext)
        if isSelecting {
            exitSelectionMode()
        }
    }

    private func promptNewAlbum(with photos: [Photo]) {
        photosPendingNewAlbum = photos
        newAlbumName = ""
        showingNewAlbumAlert = true
    }

    private func commitNewAlbum() {
        let trimmed = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = AlbumOperations.createAlbum(named: trimmed.isEmpty ? "未命名相簿" : trimmed, in: modelContext)
        AlbumOperations.add(photosPendingNewAlbum, to: album, in: modelContext)
        photosPendingNewAlbum = []
        if isSelecting {
            exitSelectionMode()
        }
    }
}

/// 「添加到相簿」菜单内容：现有相簿列表 + 新建入口
struct AddToAlbumMenuContent: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortIndex) private var allAlbums: [Album]
    @Environment(PrivacyLock.self) private var privacyLock

    /// 隐藏的相簿只在隐藏内容解锁后列出
    private var albums: [Album] {
        allAlbums.filter { !$0.isHidden || privacyLock.isHiddenUnlocked }
    }

    let photos: [Photo]
    /// 不列出的相簿（在相簿内选择时排除它自己）
    var excludingAlbumID: UUID?
    var onNewAlbum: () -> Void
    var onAdded: (() -> Void)?

    var body: some View {
        ForEach(albums.filter { $0.id != excludingAlbumID }) { album in
            Button(album.name, systemImage: "rectangle.stack") {
                AlbumOperations.add(photos, to: album, in: modelContext)
                onAdded?()
            }
        }
        if albums.contains(where: { $0.id != excludingAlbumID }) {
            Divider()
        }
        Button("新建相簿…", systemImage: "plus") {
            onNewAlbum()
        }
    }
}
