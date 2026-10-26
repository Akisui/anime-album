import PhotosUI
import SwiftData
import SwiftUI

struct AlbumDetailView: View {
    let album: Album

    @Environment(\.modelContext) private var modelContext
    @Environment(ViewerPresenter.self) private var viewerPresenter
    @Environment(SelectionBarPresenter.self) private var selectionBarPresenter
    @State private var showingPicker = false
    // 相簿里直接导入（系统相册 / 文件）：先进图库（按内容哈希去重），再加入本相簿
    @State private var importer = PhotoImporter()
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var frameBox = GridFrameBox()

    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var photosPendingRemoval: [Photo] = []
    @State private var photosPendingNewAlbum: [Photo] = []
    @State private var showingNewAlbumAlert = false
    @State private var newAlbumName = ""

    private var photos: [Photo] {
        album.sortedPhotos
    }

    private var selectedPhotos: [Photo] {
        photos.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if photos.isEmpty {
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
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        // 选择中不能返回（底部栏属于这一页），与原生一致：先「取消」再离开
        .navigationBarBackButtonHidden(isSelecting)
        .toolbar { toolbarContent }
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
        .photosPicker(isPresented: $showingPhotosPicker, selection: $pickerItems, matching: .images)
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
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !photos.isEmpty {
                    Button("选择") { enterSelectionMode() }
                }
                Menu {
                    addMenuItems
                } label: {
                    Label("添加照片", systemImage: "plus")
                }
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
