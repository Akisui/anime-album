import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// PDF 的单页（DESIGN.md §8.3）：PDF 在查看器里按页当作一张张图片浏览。
/// - 矢量页（有文字 / 路径）保持矢量：不转位图，从原 PDF 按需渲染（查看器放大时分块重绘，任意倍数都清晰）
/// - 扫描页（整页只有一张图）转成无损图片：原图是 JPEG / JPEG 2000 时原样取出字节，
///   其他编码按图片原生分辨率渲染成 PNG
struct PDFPageInfo: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case vector
        case raster
    }

    var kind: Kind
    /// 扫描页提取出的图片文件名（pages/<uuid>/ 下）
    var file: String?
    /// 显示尺寸：矢量页为点（已按页面旋转），扫描页为像素 —— 只用于宽高比
    var width: Double
    var height: Double

    var aspectRatio: CGFloat {
        height > 0 ? CGFloat(width / height) : 1
    }
}

/// 页面清单与页面图片的读写。导入时生成清单（pages/<uuid>/manifest.json）和每页的预览图
/// （large-n.png / tiny-n.png）；早于此导入的 PDF 在第一次打开时补生成
final class PDFPageStore: @unchecked Sendable {
    static let shared = PDFPageStore()

    private let lock = NSLock()
    private var manifests: [UUID: [PDFPageInfo]] = [:]
    private var documents: [UUID: CGPDFDocument] = [:]
    /// 页面渲染 / 解码串行进行（CGPDFDocument 不保证并发安全，且大页面渲染占内存）
    private let renderQueue = DispatchQueue(label: "PDFPageStore.render", qos: .userInitiated)

    private func directory(photoID: UUID) -> URL {
        ImageStore.shared.url(forRelativePath: "pages/\(photoID.uuidString)")
    }

    /// 清单带版本号：拆页规则改了就换文件名，旧 PDF 在启动后由 upgrade 在后台按新规则重做
    /// （v2：整页都是图片的扫描页按图片覆盖区域裁掉白边、不抗锯齿；忽略隐藏 OCR 文字）
    private func manifestURL(photoID: UUID) -> URL {
        directory(photoID: photoID).appendingPathComponent("manifest-v2.json")
    }

    private func legacyManifestURL(photoID: UUID) -> URL {
        directory(photoID: photoID).appendingPathComponent("manifest.json")
    }

    private let upgradeQueue = DispatchQueue(label: "PDFPageStore.upgrade", qos: .utility)

    /// 启动后在后台把旧规则拆的 PDF 重做一遍（已是新版的跳过）
    func upgrade(photoIDs: [UUID]) {
        upgradeQueue.async {
            for photoID in photoIDs where !FileManager.default.fileExists(atPath: self.manifestURL(photoID: photoID).path) {
                self.prepare(photoID: photoID)
                try? FileManager.default.removeItem(at: self.legacyManifestURL(photoID: photoID))
            }
        }
    }

    private func pdfURL(photoID: UUID) -> URL? {
        ImageStore.shared.originalURL(photoID: photoID)
    }

    // MARK: - 清单

    /// 拆页：逐页分析、提取扫描页图片、生成预览图（导入时就做好，查看时只解码 —— 翻页时现场渲染会卡），
    /// 最后写清单。progress(已处理页数, 总页数) 在当前线程回调（导入进度显示「第 x / n 页」）
    @discardableResult
    func prepare(photoID: UUID, pdfData: Data? = nil,
                 progress: (@Sendable (Int, Int) -> Void)? = nil) -> [PDFPageInfo] {
        let document: CGPDFDocument?
        if let pdfData, let provider = CGDataProvider(data: pdfData as CFData) {
            document = CGPDFDocument(provider)
        } else {
            document = pdfURL(photoID: photoID).flatMap { CGPDFDocument($0 as CFURL) }
        }
        guard let document, document.numberOfPages > 0 else { return [] }
        let directory = directory(photoID: photoID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let count = document.numberOfPages
        progress?(0, count)
        var pages: [PDFPageInfo] = []
        for number in 1...count {
            guard let page = document.page(at: number) else { continue }
            let size = Self.displaySize(of: page)
            var info = PDFPageInfo(kind: .vector, width: size.width, height: size.height)
            if let raster = Self.extractRaster(page: page, index: number - 1, into: directory) {
                info = raster
            }
            pages.append(info)
            for kind in [PreviewKind.large, .tiny] {
                writePreview(photoID: photoID, index: pages.count - 1, info: info, page: page, kind: kind)
            }
            progress?(number, count)
        }
        if let data = try? JSONEncoder().encode(pages) {
            try? data.write(to: manifestURL(photoID: photoID), options: .atomic)
        }
        lock.withLock {
            manifests[photoID] = pages
            if documents[photoID] == nil {
                documents[photoID] = document
            }
        }
        return pages
    }

    /// 页面清单（同步；内存缓存 → 磁盘 → 旧版清单（后台升级中）→ 现场补生成）
    func pages(photoID: UUID) -> [PDFPageInfo] {
        if let cached = lock.withLock({ manifests[photoID] }) {
            return cached
        }
        if let data = try? Data(contentsOf: manifestURL(photoID: photoID)),
           let pages = try? JSONDecoder().decode([PDFPageInfo].self, from: data), !pages.isEmpty {
            lock.withLock { manifests[photoID] = pages }
            return pages
        }
        // 旧版清单：先照旧显示（不缓存），等后台升级完成
        if let data = try? Data(contentsOf: legacyManifestURL(photoID: photoID)),
           let pages = try? JSONDecoder().decode([PDFPageInfo].self, from: data), !pages.isEmpty {
            return pages
        }
        return prepare(photoID: photoID)
    }

    func deleteFiles(photoID: UUID) {
        try? FileManager.default.removeItem(at: directory(photoID: photoID))
        lock.withLock {
            manifests[photoID] = nil
            documents[photoID] = nil
        }
    }

    // MARK: - 渲染

    /// 预览图规格：large 给查看器（长边 2048，放大后矢量页分块重绘、扫描页换原图），tiny 给胶片条
    enum PreviewKind: String {
        case large
        case tiny

        var maxPixel: Int {
            switch self {
            case .large: 2048
            case .tiny: 240
            }
        }
    }

    private func previewURL(photoID: UUID, page: Int, kind: PreviewKind) -> URL {
        directory(photoID: photoID).appendingPathComponent("\(kind.rawValue)-\(page + 1).png")
    }

    /// 页面预览图：导入时就生成好（PNG，无损），这里只解码；缺了（早先导入的 PDF）现场生成并补存
    func previewImage(photoID: UUID, page: Int, kind: PreviewKind) async -> UIImage? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                continuation.resume(returning: self.loadOrMakePreview(photoID: photoID, page: page, kind: kind))
            }
        }
    }

    /// 扫描页的原图（放大查看用，无损）；长边超过 8192 时缩到 8192
    func fullImage(photoID: UUID, page: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                let pages = self.pages(photoID: photoID)
                guard pages.indices.contains(page), pages[page].kind == .raster, let file = pages[page].file else {
                    continuation.resume(returning: nil)
                    return
                }
                let url = self.directory(photoID: photoID).appendingPathComponent(file)
                continuation.resume(returning: Self.decode(url: url, maxPixel: 8192))
            }
        }
    }

    private func loadOrMakePreview(photoID: UUID, page: Int, kind: PreviewKind) -> UIImage? {
        let url = previewURL(photoID: photoID, page: page, kind: kind)
        if let image = Self.decode(url: url, maxPixel: nil) {
            return image
        }
        return makePreview(photoID: photoID, page: page, kind: kind)
    }

    /// 缺预览图（早先导入的 PDF）时现场生成并补存
    private func makePreview(photoID: UUID, page index: Int, kind: PreviewKind) -> UIImage? {
        let pages = pages(photoID: photoID)
        guard pages.indices.contains(index), let page = cgPage(photoID: photoID, index: index) else { return nil }
        return writePreview(photoID: photoID, index: index, info: pages[index], page: page, kind: kind)
    }

    @discardableResult
    private func writePreview(photoID: UUID, index: Int, info: PDFPageInfo, page: CGPDFPage,
                              kind: PreviewKind) -> UIImage? {
        let image: UIImage?
        if info.kind == .raster, let file = info.file {
            image = Self.decode(url: directory(photoID: photoID).appendingPathComponent(file), maxPixel: kind.maxPixel)
        } else {
            let size = Self.displaySize(of: page)
            image = Self.render(page: page, scale: CGFloat(kind.maxPixel) / max(size.width, size.height))
        }
        if let data = image?.pngData() {
            try? data.write(to: previewURL(photoID: photoID, page: index, kind: kind), options: .atomic)
        }
        return image
    }

    private static func decode(url: URL, maxPixel: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixel {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        } else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height, 1)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// 矢量页的 CGPDFPage（查看器放大时分块重绘用）
    func cgPage(photoID: UUID, index: Int) -> CGPDFPage? {
        let document: CGPDFDocument? = lock.withLock {
            if let cached = documents[photoID] {
                return cached
            }
            let opened = pdfURL(photoID: photoID).flatMap { CGPDFDocument($0 as CFURL) }
            documents[photoID] = opened
            return opened
        }
        return document?.page(at: index + 1)
    }

    /// 页面按显示方向（已旋转）、白底渲染；scale：每点多少像素
    /// antialias=false：整页都是图片时用 —— 几条图片拼成一页的扫描件，抗锯齿会在拼接处留下白色细缝
    static func render(page: CGPDFPage, scale: CGFloat, interpolate: Bool = true, antialias: Bool = true) -> UIImage? {
        let size = displaySize(of: page)
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            let cgContext = context.cgContext
            if !interpolate {
                cgContext.interpolationQuality = .none
            }
            if !antialias {
                cgContext.setShouldAntialias(false)
            }
            draw(page: page, in: cgContext, size: pixelSize)
        }
    }

    /// 把页面画进 UIKit 坐标系（原点左上）的 size 区域（与页面同宽高比），按页面旋转摆正
    static func draw(page: CGPDFPage, in context: CGContext, size: CGSize) {
        let display = displaySize(of: page)
        guard display.width > 0, display.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: size.width / display.width, y: -size.height / display.height)
        // 目标矩形取显示尺寸本身：只做旋转 + 平移、不缩放（getDrawingTransform 不会放大超过 1 倍）
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: display),
                                                     rotate: 0, preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// 页面显示尺寸（点）：cropBox 按 /Rotate 旋转后
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        return rotated ? CGSize(width: box.height, height: box.width) : box.size
    }

    // MARK: - 扫描页识别与提取

    /// 整页只有图片（一张，或几条拼成一页）、没有可见文字和矢量绘制、图片铺满页面 → 扫描页，转无损图片。
    /// 扫描件常带隐藏的 OCR 文字层（文字渲染模式 3），不算可见文字
    private static func extractRaster(page: CGPDFPage, index: Int, into directory: URL) -> PDFPageInfo? {
        let scan = PageContentScan(page: page)
        guard scan.paintsVector == false, scan.showsText == false, let first = scan.images.first else {
            return nil
        }
        let box = page.getBoxRect(.cropBox)
        let union = scan.images.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let covered = union.intersection(box)
        guard !covered.isNull, covered.width * covered.height >= box.width * box.height * 0.98 else { return nil }
        if scan.images.count == 1, let passthrough = jpegPassthrough(page: page, placed: first, index: index,
                                                                    into: directory) {
            return passthrough
        }
        // 按图片原生分辨率（多张取最密的）渲染整页成 PNG：不插值、不抗锯齿（拼接处不留缝）
        let pixelsPerPoint = scan.images.map { placed -> CGFloat in
            guard let size = pixelSize(of: placed.stream) else { return 1 }
            let pixels = placed.isQuarterTurned ? size.height : size.width
            return CGFloat(pixels) / max(placed.rect.width, 1)
        }.max() ?? 1
        let display = displaySize(of: page)
        let longest = max(display.width, display.height) * pixelsPerPoint
        let scale = longest > 8192 ? pixelsPerPoint * 8192 / longest : pixelsPerPoint
        guard var image = render(page: page, scale: scale, interpolate: false, antialias: false) else { return nil }
        // 只留图片实际覆盖的区域：扫描图没铺满页面（差零点几 pt）时，露出的白色页底会成为贴边的白色细线
        if page.rotationAngle % 360 == 0, let cgImage = image.cgImage {
            let pixelRect = CGRect(x: (covered.minX - box.minX) * scale, y: (box.maxY - covered.maxY) * scale,
                                   width: covered.width * scale, height: covered.height * scale)
            let inward = CGRect(x: ceil(pixelRect.minX), y: ceil(pixelRect.minY),
                                width: floor(pixelRect.maxX) - ceil(pixelRect.minX),
                                height: floor(pixelRect.maxY) - ceil(pixelRect.minY))
            if inward.width > 0, inward.height > 0, inward.size != CGSize(width: cgImage.width, height: cgImage.height),
               let cropped = cgImage.cropping(to: inward) {
                image = UIImage(cgImage: cropped)
            }
        }
        guard let png = image.pngData() else { return nil }
        let file = "\(index + 1).png"
        guard (try? png.write(to: directory.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
        return PDFPageInfo(kind: .raster, file: file,
                           width: Double(image.size.width), height: Double(image.size.height))
    }

    private static func pixelSize(of stream: CGPDFStreamRef) -> (width: Int, height: Int)? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
              CGPDFDictionaryGetInteger(dictionary, "Height", &height), width > 0, height > 0
        else {
            return nil
        }
        return (width, height)
    }

    /// 单张铺满的图片是 JPEG / JPEG 2000 时，原样取出字节（与 PDF 里的数据逐字节相同）
    private static func jpegPassthrough(page: CGPDFPage, placed: PageContentScan.PlacedImage, index: Int,
                                        into directory: URL) -> PDFPageInfo? {
        guard let dictionary = CGPDFStreamGetDictionary(placed.stream), let size = pixelSize(of: placed.stream) else {
            return nil
        }
        // 条件：页面未旋转、图片正放、无遮罩 / 解码数组、颜色空间是 RGB 或灰度（CMYK JPEG 在 PDF 外常被反色）
        var format = CGPDFDataFormat.raw
        guard page.rotationAngle % 360 == 0, placed.isUpright,
              !hasKey(dictionary, "SMask"), !hasKey(dictionary, "Mask"), !hasKey(dictionary, "Decode"),
              isRGBOrGray(dictionary),
              let data = CGPDFStreamCopyData(placed.stream, &format) as Data?,
              format == .jpegEncoded || format == .JPEG2000
        else {
            return nil
        }
        let file = "\(index + 1).\(format == .jpegEncoded ? "jpg" : "jp2")"
        let url = directory.appendingPathComponent(file)
        if (try? data.write(to: url, options: .atomic)) != nil,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            return PDFPageInfo(kind: .raster, file: file, width: Double(size.width), height: Double(size.height))
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    private static func hasKey(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object)
    }

    private static func isRGBOrGray(_ dictionary: CGPDFDictionaryRef) -> Bool {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            return ["DeviceRGB", "DeviceGray", "CalRGB", "CalGray"].contains(String(cString: name))
        }
        // [/ICCBased stream]：按通道数判断（3 = RGB，1 = 灰度）
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array {
            var family: UnsafePointer<CChar>?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetName(array, 0, &family), let family, String(cString: family) == "ICCBased",
               CGPDFArrayGetStream(array, 1, &stream), let stream, let profile = CGPDFStreamGetDictionary(stream) {
                var channels: CGPDFInteger = 0
                return CGPDFDictionaryGetInteger(profile, "N", &channels) && (channels == 3 || channels == 1)
            }
        }
        return false
    }
}

/// 扫描一页的内容流：记录图片绘制（及其在页面上的位置）、是否有文字和矢量绘制
private final class PageContentScan {
    struct PlacedImage {
        let stream: CGPDFStreamRef
        let rect: CGRect
        /// 图片正放（无旋转 / 翻转）
        let isUpright: Bool
        /// 图片转了 90°（像素宽对应页面上的高）
        let isQuarterTurned: Bool
    }

    private(set) var images: [PlacedImage] = []
    private(set) var paintsVector = false
    private(set) var showsText = false

    private var ctm = CGAffineTransform.identity
    /// 文字渲染模式（Tr）：3 = 不可见（扫描件的 OCR 文字层）
    private var textRenderMode = 0
    private var stack: [(CGAffineTransform, Int)] = []
    private let xObjects: CGPDFDictionaryRef?

    init(page: CGPDFPage) {
        xObjects = Self.xObjectDictionary(of: page)
        guard let table = CGPDFOperatorTableCreate() else { return }
        func set(_ names: [String], _ callback: CGPDFOperatorCallback) {
            for name in names {
                CGPDFOperatorTableSetCallback(table, name, callback)
            }
        }
        set(["q"]) { _, info in
            let scan = PageContentScan.from(info)
            scan.stack.append((scan.ctm, scan.textRenderMode))
        }
        set(["Q"]) { _, info in
            let scan = PageContentScan.from(info)
            if let (ctm, mode) = scan.stack.popLast() {
                scan.ctm = ctm
                scan.textRenderMode = mode
            }
        }
        set(["cm"]) { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
                                           tx: values[4], ty: values[5])
            let scan = PageContentScan.from(info)
            scan.ctm = matrix.concatenating(scan.ctm)
        }
        set(["Do"]) { scanner, info in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            PageContentScan.from(info).drawXObject(named: name)
        }
        set(["f", "F", "f*", "S", "s", "B", "B*", "b", "b*", "sh", "BI"]) { _, info in
            PageContentScan.from(info).paintsVector = true
        }
        set(["Tr"]) { scanner, info in
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) {
                PageContentScan.from(info).textRenderMode = mode
            }
        }
        set(["Tj", "TJ", "'", "\""]) { _, info in
            let scan = PageContentScan.from(info)
            if scan.textRenderMode != 3 {
                scan.showsText = true
            }
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
    }

    private static func from(_ info: UnsafeMutableRawPointer?) -> PageContentScan {
        Unmanaged<PageContentScan>.fromOpaque(info!).takeUnretainedValue()
    }

    private func drawXObject(named name: UnsafePointer<CChar>) {
        var stream: CGPDFStreamRef?
        guard let xObjects, CGPDFDictionaryGetStream(xObjects, name, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream)
        else {
            paintsVector = true
            return
        }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "Image"
        else {
            // 表单 XObject 等：当作矢量内容（保守）
            paintsVector = true
            return
        }
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
        let upright = abs(ctm.b) < 0.001 && abs(ctm.c) < 0.001 && ctm.a > 0 && ctm.d > 0
        let quarter = abs(ctm.a) < 0.001 && abs(ctm.d) < 0.001
        images.append(PlacedImage(stream: stream, rect: rect, isUpright: upright, isQuarterTurned: quarter))
    }

    /// 页面的 /Resources /XObject（Resources 可继承自父节点）
    private static func xObjectDictionary(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        while let current = node {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                var xObjects: CGPDFDictionaryRef?
                return CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects) ? xObjects : nil
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return nil
    }
}
