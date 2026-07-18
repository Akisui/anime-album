import SwiftData
import SwiftUI

struct AlbumsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortIndex) private var albums: [Album]

    @State private var showingNewAlbum = false
    @State private var newAlbumName = ""
    @State private var renamingAlbum: Album?
    @State private var renameText = ""
    @State private var deletingAlbum: Album?
    @State private var navigationPath = NavigationPath()

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if albums.isEmpty {
                    ContentUnavailableView {
                        Label("没有相簿", systemImage: "rectangle.stack")
                    } description: {
                        Text("轻点右上角的 + 创建第一个相簿。")
                    }
                } else {
                    albumsGrid
                }
            }
            .navigationTitle("相簿")
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新建相簿", systemImage: "plus") {
                        newAlbumName = ""
                        showingNewAlbum = true
                    }
                }
            }
            .alert("新建相簿", isPresented: $showingNewAlbum) {
                TextField("相簿名称", text: $newAlbumName)
                Button("取消", role: .cancel) {}
                Button("存储") {
                    AlbumOperations.createAlbum(named: normalizedName(newAlbumName), in: modelContext)
                }
            } message: {
                Text("为此相簿输入一个名称。")
            }
            .alert("重命名相簿", isPresented: renameAlertPresented) {
                TextField("相簿名称", text: $renameText)
                Button("取消", role: .cancel) { renamingAlbum = nil }
                Button("存储") {
                    renamingAlbum?.name = normalizedName(renameText)
                    renamingAlbum = nil
                }
            }
            .confirmationDialog(
                "删除相簿「\(deletingAlbum?.name ?? "")」？",
                isPresented: deleteDialogPresented,
                titleVisibility: .visible
            ) {
                Button("删除相簿", role: .destructive) {
                    if let album = deletingAlbum {
                        modelContext.delete(album)
                    }
                    deletingAlbum = nil
                }
            } message: {
                Text("相簿中的照片不会被删除，仍保留在图库中。")
            }
            .task {
                #if DEBUG
                // 调试辅助：OPEN_ALBUM=1 直接进入第一个相簿，方便自动化截图
                if ProcessInfo.processInfo.environment["OPEN_ALBUM"] == "1", let first = albums.first {
                    navigationPath.append(first)
                }
                #endif
            }
        }
    }

    private var albumsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") {
                            renameText = album.name
                            renamingAlbum = album
                        }
                        Button("删除相簿", systemImage: "trash", role: .destructive) {
                            deletingAlbum = album
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renamingAlbum != nil }, set: { if !$0 { renamingAlbum = nil } })
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { deletingAlbum != nil }, set: { if !$0 { deletingAlbum = nil } })
    }

    private func normalizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名相簿" : trimmed
    }
}

/// 相簿卡片：方形圆角封面 + 名称 + 数量（原生相册样式）
struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AlbumCoverView(photo: album.coverPhoto)
            Text(album.name)
                .font(.callout)
                .lineLimit(1)
                .padding(.top, 6)
            Text("\(album.photoCount)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct AlbumCoverView: View {
    let photo: Photo?

    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: photo?.id) {
                guard let photo else {
                    image = nil
                    return
                }
                image = await ThumbnailCache.shared.image(for: photo.id, kind: .small)
            }
    }
}
