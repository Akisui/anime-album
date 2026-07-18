import SwiftData
import SwiftUI

/// 从图库多选照片加入相簿（已在相簿中的照片不再显示）
struct AlbumPhotoPickerSheet: View {
    let album: Album

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Photo.createdAt) private var allPhotos: [Photo]
    @State private var selectedIDs: Set<UUID> = []

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    private var candidates: [Photo] {
        let existing = Set(album.sortedPhotos.map(\.id))
        return allPhotos.filter { !existing.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView {
                        Label("没有可添加的照片", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("图库中的照片都已在这个相簿里。")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(candidates) { photo in
                                PhotoGridCell(photo: photo, isSelected: selectedIDs.contains(photo.id))
                                    .onTapGesture { toggle(photo) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加到「\(album.name)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加 (\(selectedIDs.count))") { addSelected() }
                        .fontWeight(.semibold)
                        .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }

    private func toggle(_ photo: Photo) {
        if selectedIDs.contains(photo.id) {
            selectedIDs.remove(photo.id)
        } else {
            selectedIDs.insert(photo.id)
        }
    }

    private func addSelected() {
        let photos = candidates.filter { selectedIDs.contains($0.id) }
        AlbumOperations.add(photos, to: album, in: modelContext)
        dismiss()
    }
}
