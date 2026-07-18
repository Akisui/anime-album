import SwiftUI

/// 照片网格单元：正方形、aspectFill、无圆角（原生相册样式，DESIGN.md §6.1）
struct PhotoGridCell: View {
    let photo: Photo
    var isSelected = false

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay {
                if isSelected {
                    Color.white.opacity(0.3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                        .font(.body)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .task(id: photo.id) {
                image = await ThumbnailCache.shared.image(for: photo.id, kind: .small)
            }
    }
}
