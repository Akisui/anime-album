import SwiftData
import SwiftUI

/// 从图库多选照片加入相簿（已在相簿中的照片不再显示）。
/// 支持轻点单选与横向起手的滑动连选（见 SelectablePhotoGrid）。
struct AlbumPhotoPickerSheet: View {
    let album: Album

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Photo.createdAt) private var allPhotos: [Photo]
    @State private var selectedIDs: Set<UUID> = []

    private var candidates: [Photo] {
        let existing = Set((album.entries ?? []).compactMap { $0.photo?.id })
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
                    // 内容延伸到导航栏与 Home 指示条下方，由 UIKit 的 adjustedContentInset 让出位置
                    SelectablePhotoGrid(photos: candidates, selectedIDs: $selectedIDs)
                        .ignoresSafeArea()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    header
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { addSelected() }
                        .fontWeight(.semibold)
                        .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .task {
            #if DEBUG
            // 调试辅助：PICKER_SELECT=n 预选前 n 张，截图验证勾选样式
            if let raw = ProcessInfo.processInfo.environment["PICKER_SELECT"], let count = Int(raw) {
                selectedIDs = Set(candidates.prefix(count).map(\.id))
            }
            #endif
        }
    }

    /// 两行标题：目标相簿 + 状态（未选时提示可滑动连选，选中后显示数量）
    private var header: some View {
        VStack(spacing: 1) {
            Text("添加到「\(album.name)」")
                .font(.headline)
                .lineLimit(1)
            SelectionCountLabel(count: selectedIDs.count, unit: "张照片", placeholder: "轻点或横向滑动以选择")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func addSelected() {
        let photos = candidates.filter { selectedIDs.contains($0.id) }
        AlbumOperations.add(photos, to: album, in: modelContext)
        dismiss()
    }
}
