import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ThumbnailKind: String, Sendable, CaseIterable {
    case small
    case large

    var maxPixelSize: Int {
        switch self {
        case .small: 512
        case .large: 2048
        }
    }
}

struct StoredImage: Sendable {
    let relativePath: String
    let width: Int
    let height: Int
}

enum ImageStoreError: Error {
    case unreadableImage
    case thumbnailFailed
}

/// 图片文件的落盘与读取。目录布局见 DESIGN.md §4.3：
/// originals/<uuid前2位>/<uuid>.<ext> + thumbnails/{small,large}/<uuid>.heic
final class ImageStore: Sendable {
    static let shared = try! ImageStore()

    private let baseURL: URL

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        baseURL = support.appendingPathComponent("PhotoLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        for kind in ThumbnailKind.allCases {
            try FileManager.default.createDirectory(at: thumbnailsURL(kind), withIntermediateDirectories: true)
        }
        // 缩略图可随时重建，不进备份
        var thumbnailsRoot = baseURL.appendingPathComponent("thumbnails", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? thumbnailsRoot.setResourceValues(values)
    }

    // MARK: - 路径

    private var originalsURL: URL {
        baseURL.appendingPathComponent("originals", isDirectory: true)
    }

    private func thumbnailsURL(_ kind: ThumbnailKind) -> URL {
        baseURL.appendingPathComponent("thumbnails/\(kind.rawValue)", isDirectory: true)
    }

    func url(forRelativePath path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func thumbnailURL(photoID: UUID, kind: ThumbnailKind) -> URL {
        thumbnailsURL(kind).appendingPathComponent("\(photoID.uuidString).heic")
    }

    // MARK: - 写入

    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func store(data: Data, photoID: UUID) throws -> StoredImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ImageStoreError.unreadableImage
        }

        let ext = Self.fileExtension(for: source)
        let bucket = String(photoID.uuidString.prefix(2)).lowercased()
        let relativePath = "originals/\(bucket)/\(photoID.uuidString).\(ext)"
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        do {
            for kind in ThumbnailKind.allCases {
                try writeThumbnail(from: source, photoID: photoID, kind: kind)
            }
        } catch {
            deleteFiles(relativePath: relativePath, photoID: photoID)
            throw error
        }

        let (width, height) = Self.pixelSize(of: source)
        return StoredImage(relativePath: relativePath, width: width, height: height)
    }

    private func writeThumbnail(from source: CGImageSource, photoID: UUID, kind: ThumbnailKind) throws {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: kind.maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageStoreError.thumbnailFailed
        }
        let url = thumbnailURL(photoID: photoID, kind: kind)
        // HEIC 优先；无 HEIC 编码器的环境（如部分模拟器）退回 JPEG。
        // 文件名固定 .heic，解码按内容识别，不受影响。
        if !Self.write(cgImage, to: url, type: .heic, quality: 0.75),
           !Self.write(cgImage, to: url, type: .jpeg, quality: 0.82) {
            throw ImageStoreError.thumbnailFailed
        }
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)
        else {
            return false
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - 读取

    func loadThumbnail(photoID: UUID, kind: ThumbnailKind) -> UIImage? {
        let url = thumbnailURL(photoID: photoID, kind: kind)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        #if targetEnvironment(simulator)
        // 模拟器上 preparingForDisplay 对 HEIC 会返回空白位图，跳过预解码
        return image
        #else
        return image.preparingForDisplay() ?? image
        #endif
    }

    // MARK: - 删除

    func deleteFiles(relativePath: String, photoID: UUID) {
        try? FileManager.default.removeItem(at: url(forRelativePath: relativePath))
        for kind in ThumbnailKind.allCases {
            try? FileManager.default.removeItem(at: thumbnailURL(photoID: photoID, kind: kind))
        }
    }

    // MARK: - 私有

    private static func fileExtension(for source: CGImageSource) -> String {
        guard let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String),
              let ext = type.preferredFilenameExtension
        else {
            return "img"
        }
        return ext
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        // EXIF 方向 5-8 表示图像需旋转 90°，宽高互换
        return orientation >= 5 ? (height, width) : (width, height)
    }
}
