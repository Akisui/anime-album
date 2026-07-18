import PhotosUI
import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ViewerPresenter.self) private var viewerPresenter
    @Query(sort: \Photo.createdAt) private var photos: [Photo]

    @State private var importer = PhotoImporter()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var cellFrames = CellFrameStore()

    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var photosPendingDeletion: [Photo] = []
    @State private var photosPendingNewAlbum: [Photo] = []
    @State private var showingNewAlbumAlert = false
    @State private var newAlbumName = ""

    // 捏合缩放列数（DESIGN.md §6.1）：三档单元格目标尺寸
    private static let gridTargets: [CGFloat] = [76, 110, 168]
    @State private var gridLevel = 1
    @State private var pinchReference: CGFloat = 1

    private var columns: [GridItem] {
        let target = Self.gridTargets[gridLevel]
        return [GridItem(.adaptive(minimum: target, maximum: target * 1.8), spacing: 2)]
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .overlay(alignment: .bottom) { importStatusOverlay }
        }
        .task {
            #if DEBUG
            // 调试辅助：OPEN_VIEWER=1 自动打开查看器（最后一张），方便自动化截图
            if ProcessInfo.processInfo.environment["OPEN_VIEWER"] == "1", !photos.isEmpty {
                try? await Task.sleep(for: .seconds(0.5))
                openViewer(at: photos.count - 1)
            }
            #endif
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $pickerItems, matching: .images)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
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
        if photos.isEmpty {
            ContentUnavailableView {
                Label("没有照片", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("轻点右上角的 + 导入第一张角色图片。")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
                        PhotoGridCell(photo: photo, isSelected: isSelecting && selectedIDs.contains(photo.id))
                            // 照片在查看器中时格子留空，关闭动画结束才恢复（原生同款逻辑）
                            .opacity(viewerPresenter.hiddenPhotoID == photo.id ? 0 : 1)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { frame in
                                cellFrames.frames[photo.id] = frame
                            }
                            .onTapGesture { handleTap(photo) }
                            .contextMenu {
                                if !isSelecting {
                                    cellContextMenu(for: photo)
                                }
                            }
                    }
                }
                Text("\(photos.count) 张照片")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
            // 原生相册进入图库时定位到最新照片（列表底部）
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(pinchToZoomColumns)
        }
    }

    @ViewBuilder
    private func cellContextMenu(for photo: Photo) -> some View {
        Menu("添加到相簿", systemImage: "rectangle.stack.badge.plus") {
            AddToAlbumMenuContent(photos: [photo]) {
                promptNewAlbum(with: [photo])
            }
        }
        Button("删除", systemImage: "trash", role: .destructive) {
            photosPendingDeletion = [photo]
        }
    }

    // MARK: - 工具栏

    private var navigationTitle: String {
        guard isSelecting else { return "图库" }
        return selectedIDs.isEmpty ? "选择照片" : "已选择 \(selectedIDs.count) 张"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !photos.isEmpty {
                Button(isSelecting ? "完成" : "选择") {
                    withAnimation { toggleSelectionMode() }
                }
            }
            if !isSelecting {
                Menu {
                    Button("从照片图库", systemImage: "photo.on.rectangle") {
                        showingPhotosPicker = true
                    }
                    Button("从文件", systemImage: "folder") {
                        showingFileImporter = true
                    }
                } label: {
                    Label("导入", systemImage: "plus")
                }
            }
        }
        if isSelecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Menu("添加到相簿") {
                    AddToAlbumMenuContent(photos: selectedPhotos) {
                        promptNewAlbum(with: selectedPhotos)
                    } onAdded: {
                        exitSelectionMode()
                    }
                }
                .disabled(selectedIDs.isEmpty)
                Spacer()
                Button("删除", systemImage: "trash", role: .destructive) {
                    photosPendingDeletion = selectedPhotos
                }
                .disabled(selectedIDs.isEmpty)
            }
        }
    }

    // MARK: - 导入状态

    @ViewBuilder
    private var importStatusOverlay: some View {
        if importer.isImporting {
            VStack(spacing: 6) {
                ProgressView(value: Double(importer.completed), total: Double(max(importer.total, 1)))
                Text("正在导入 \(importer.completed)/\(importer.total)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 12)
        } else if let summary = importer.summary {
            Text(summary)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .task {
                    try? await Task.sleep(for: .seconds(2.5))
                    importer.summary = nil
                }
        }
    }

    // MARK: - 交互

    /// 捏合切换网格档位：放大手势 → 更大的单元格（更少列），反之亦然
    private var pinchToZoomColumns: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let ratio = value.magnification / pinchReference
                if ratio > 1.3, gridLevel < Self.gridTargets.count - 1 {
                    pinchReference = value.magnification
                    withAnimation(.snappy) { gridLevel += 1 }
                } else if ratio < 0.75, gridLevel > 0 {
                    pinchReference = value.magnification
                    withAnimation(.snappy) { gridLevel -= 1 }
                }
            }
            .onEnded { _ in
                pinchReference = 1
            }
    }

    private var selectedPhotos: [Photo] {
        photos.filter { selectedIDs.contains($0.id) }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { !photosPendingDeletion.isEmpty },
            set: { if !$0 { photosPendingDeletion = [] } }
        )
    }

    private func handleTap(_ photo: Photo) {
        if isSelecting {
            if selectedIDs.contains(photo.id) {
                selectedIDs.remove(photo.id)
            } else {
                selectedIDs.insert(photo.id)
            }
        } else if let index = photos.firstIndex(where: { $0.id == photo.id }) {
            openViewer(at: index)
        }
    }

    private func openViewer(at index: Int) {
        let store = cellFrames
        viewerPresenter.present(photos: photos, index: index) { id in
            store.frames[id]
        }
    }

    private func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting {
            selectedIDs = []
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIDs = []
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
    @Query(sort: \Album.sortIndex) private var albums: [Album]

    let photos: [Photo]
    var onNewAlbum: () -> Void
    var onAdded: (() -> Void)?

    var body: some View {
        ForEach(albums) { album in
            Button(album.name, systemImage: "rectangle.stack") {
                AlbumOperations.add(photos, to: album, in: modelContext)
                onAdded?()
            }
        }
        if !albums.isEmpty {
            Divider()
        }
        Button("新建相簿…", systemImage: "plus") {
            onNewAlbum()
        }
    }
}
