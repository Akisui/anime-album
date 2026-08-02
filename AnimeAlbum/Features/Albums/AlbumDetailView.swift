import SwiftData
import SwiftUI

struct AlbumDetailView: View {
    let album: Album

    @Environment(\.modelContext) private var modelContext
    @Environment(ViewerPresenter.self) private var viewerPresenter
    @State private var showingPicker = false
    @State private var frameBox = GridFrameBox()

    private var photos: [Photo] {
        album.sortedPhotos
    }

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label("相簿是空的", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("轻点右上角的 + 从图库添加照片。")
                }
            } else {
                // UICollectionView 桥接：拖拽排序 + 捏合缩放列数 + Context Menu（DESIGN.md §6.4）
                ReorderablePhotoGrid(
                    photos: photos,
                    onTap: { index in
                        let list = photos
                        guard list.indices.contains(index) else { return }
                        let box = frameBox
                        viewerPresenter.present(
                            photos: list, index: index,
                            sourceFrame: { box.lookup?($0) },
                            sourceVisibleRect: { box.visibleRect?() })
                    },
                    onMove: { photoID, destination in
                        AlbumOperations.move(photoID: photoID, toIndex: destination, in: album, context: modelContext)
                    },
                    onSetCover: { photoID in
                        album.coverPhotoID = photoID
                    },
                    onRemove: { photoID in
                        if let photo = photos.first(where: { $0.id == photoID }) {
                            AlbumOperations.remove(photo, from: album, in: modelContext)
                        }
                    },
                    frameBox: frameBox,
                    hiddenPhotoID: viewerPresenter.hiddenPhotoID
                )
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加照片", systemImage: "plus") {
                    showingPicker = true
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            AlbumPhotoPickerSheet(album: album)
        }
    }
}
