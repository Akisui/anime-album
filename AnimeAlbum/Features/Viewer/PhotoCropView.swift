import SwiftData
import SwiftUI

/// 查看器「…」→ 编辑：裁剪（DESIGN.md §6.3）。不破坏原图：第一次裁剪时原图留作备份，
/// 再次编辑从原图和上次的裁剪框开始，框拉回整张即复原（见 ImageStore.applyCrop）
struct PhotoCropView: View {
    let photoID: UUID
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var base: ImageStore.EditingBase?
    /// 裁剪框（归一化，相对 base.image）
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect: CropAspect = .free
    @State private var isSaving = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { proxy in
                if let base {
                    CropCanvas(image: base.image, crop: $crop, aspect: aspect.ratio(for: base.image.size),
                               area: proxy.size)
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            aspectPicker
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            let id = photoID
            let loaded = await Task.detached { ImageStore.shared.editingBase(photoID: id) }.value
            base = loaded
            if let loaded {
                crop = loaded.crop
            }
            #if DEBUG
            // CROP_ASPECT=square 等（CropAspect 的 rawValue）选比例；CROP_SAVE=1 再 1s 后按「完成」
            let env = ProcessInfo.processInfo.environment
            if let raw = env["CROP_ASPECT"], let option = CropAspect(rawValue: raw), let loaded,
               let ratio = option.ratio(for: loaded.image.size) {
                aspect = option
                crop = CropCanvas.fit(ratio: ratio, around: crop, imageSize: loaded.image.size)
                    .insetBy(dx: 0.1, dy: 0.1 * ratio * loaded.image.size.height / loaded.image.size.width)
            }
            if env["CROP_SAVE"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                save()
            }
            #endif
        }
        .alert("无法存储编辑", isPresented: $failed) {
            Button("好", role: .cancel) {}
        }
    }

    private var isFull: Bool {
        crop.minX < 0.001 && crop.minY < 0.001 && crop.width > 0.999 && crop.height > 0.999
    }

    private var topBar: some View {
        HStack {
            Button("取消") { dismiss() }
            Spacer()
            Button("复原") {
                aspect = .free
                withAnimation(.easeOut(duration: 0.25)) {
                    crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
            }
            .disabled(isFull)
            Spacer()
            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("完成").fontWeight(.semibold)
                }
            }
            .foregroundStyle(.yellow)
            .disabled(base == nil || isSaving || (isFull && base?.crop == CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .foregroundStyle(.white)
    }

    private var aspectPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CropAspect.allCases) { option in
                    Button {
                        aspect = option
                        guard let base, let ratio = option.ratio(for: base.image.size) else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            crop = CropCanvas.fit(ratio: ratio, around: crop, imageSize: base.image.size)
                        }
                    } label: {
                        Text(option.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(option == aspect ? Color.white.opacity(0.25) : .clear))
                    }
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
        .padding(.bottom, 8)
    }

    private func save() {
        let id = photoID
        let rect = crop
        isSaving = true
        Task {
            let result = await Task.detached { try? ImageStore.shared.applyCrop(photoID: id, crop: rect) }.value
            isSaving = false
            guard let result else {
                failed = true
                return
            }
            var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let photo = (try? modelContext.fetch(descriptor))?.first {
                photo.width = result.width
                photo.height = result.height
                photo.fileRelativePath = result.relativePath
                photo.editRevision += 1
                try? modelContext.save()
            }
            ThumbnailCache.shared.evict(photoID: id)
            onFinish()
            dismiss()
        }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, threeFour, sixteenNine, nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "自由"
        case .original: "原始比例"
        case .square: "正方形"
        case .fourThree: "4:3"
        case .threeFour: "3:4"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }

    /// 宽 / 高；自由为 nil
    func ratio(for imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: imageSize.height > 0 ? imageSize.width / imageSize.height : 1
        case .square: 1
        case .fourThree: 4 / 3
        case .threeFour: 3 / 4
        case .sixteenNine: 16 / 9
        case .nineSixteen: 9 / 16
        }
    }
}

/// 图片 + 裁剪框：框外压暗，拖四角 / 四边调大小（锁定比例时只能拖四角），拖框内移动
struct CropCanvas: View {
    let image: UIImage
    @Binding var crop: CGRect
    let aspect: CGFloat?
    let area: CGSize

    private enum Handle {
        case move
        case corner(left: Bool, top: Bool)
        case edge(Edge)
    }

    @State private var dragStart: (handle: Handle, crop: CGRect)?

    /// 框的最小边长（点）
    private static let minSide: CGFloat = 48

    private var imageRect: CGRect {
        let size = image.size
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (area.width - fitted.width) / 2, y: (area.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private var cropRect: CGRect {
        let image = imageRect
        return CGRect(x: image.minX + crop.minX * image.width, y: image.minY + crop.minY * image.height,
                      width: crop.width * image.width, height: crop.height * image.height)
    }

    var body: some View {
        let frame = cropRect
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: imageRect.width, height: imageRect.height)
                .offset(x: imageRect.minX, y: imageRect.minY)
            // 框外压暗
            Path { path in
                path.addRect(imageRect)
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            // 三分线（拖动时显示）
            Path { path in
                for step in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(step) / 3
                    let y = frame.minY + frame.height * CGFloat(step) / 3
                    path.move(to: CGPoint(x: x, y: frame.minY))
                    path.addLine(to: CGPoint(x: x, y: frame.maxY))
                    path.move(to: CGPoint(x: frame.minX, y: y))
                    path.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(dragStart == nil ? 0 : 0.6), lineWidth: 0.5)
            Rectangle()
                .stroke(Color.white, lineWidth: 1)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            corners(of: frame)
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    /// 四角的 L 形粗线
    private func corners(of frame: CGRect) -> some View {
        Path { path in
            let length = min(20, frame.width / 2, frame.height / 2)
            for (x, dx) in [(frame.minX, length), (frame.maxX, -length)] {
                for (y, dy) in [(frame.minY, length), (frame.maxY, -length)] {
                    path.move(to: CGPoint(x: x + dx, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + dy))
                }
            }
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    guard let handle = handle(at: value.startLocation) else { return }
                    dragStart = (handle, crop)
                }
                guard let (handle, start) = dragStart else { return }
                crop = updated(start: start, handle: handle, translation: value.translation)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    dragStart = nil
                }
            }
    }

    private func handle(at point: CGPoint) -> Handle? {
        let frame = cropRect
        let reach: CGFloat = 28
        let nearLeft = abs(point.x - frame.minX) < reach
        let nearRight = abs(point.x - frame.maxX) < reach
        let nearTop = abs(point.y - frame.minY) < reach
        let nearBottom = abs(point.y - frame.maxY) < reach
        if (nearLeft || nearRight), (nearTop || nearBottom) {
            return .corner(left: nearLeft, top: nearTop)
        }
        let withinX = point.x > frame.minX - reach && point.x < frame.maxX + reach
        let withinY = point.y > frame.minY - reach && point.y < frame.maxY + reach
        if aspect == nil {
            if nearLeft, withinY { return .edge(.leading) }
            if nearRight, withinY { return .edge(.trailing) }
            if nearTop, withinX { return .edge(.top) }
            if nearBottom, withinX { return .edge(.bottom) }
        }
        return frame.contains(point) ? .move : nil
    }

    /// 在图片坐标（点）里改框，再换回归一化
    private func updated(start: CGRect, handle: Handle, translation: CGSize) -> CGRect {
        let image = imageRect
        guard image.width > 0, image.height > 0 else { return start }
        var rect = CGRect(x: start.minX * image.width, y: start.minY * image.height,
                          width: start.width * image.width, height: start.height * image.height)
        let bounds = CGRect(origin: .zero, size: image.size)
        let minSide = Self.minSide
        switch handle {
        case .move:
            rect.origin.x = min(max(rect.minX + translation.width, 0), bounds.width - rect.width)
            rect.origin.y = min(max(rect.minY + translation.height, 0), bounds.height - rect.height)
        case .edge(let edge):
            switch edge {
            case .leading:
                let x = min(max(rect.minX + translation.width, 0), rect.maxX - minSide)
                rect = CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height)
            case .trailing:
                rect.size.width = min(max(rect.width + translation.width, minSide), bounds.width - rect.minX)
            case .top:
                let y = min(max(rect.minY + translation.height, 0), rect.maxY - minSide)
                rect = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.maxY - y)
            case .bottom:
                rect.size.height = min(max(rect.height + translation.height, minSide), bounds.height - rect.minY)
            }
        case .corner(let left, let top):
            // 对角固定
            let anchor = CGPoint(x: left ? rect.maxX : rect.minX, y: top ? rect.maxY : rect.minY)
            var corner = CGPoint(x: (left ? rect.minX : rect.maxX) + translation.width,
                                 y: (top ? rect.minY : rect.maxY) + translation.height)
            corner.x = min(max(corner.x, 0), bounds.width)
            corner.y = min(max(corner.y, 0), bounds.height)
            var width = max(abs(corner.x - anchor.x), minSide)
            var height = max(abs(corner.y - anchor.y), minSide)
            if let aspect {
                // 锁定比例：取较大的一边，再受图片边界限制
                if width / height > aspect {
                    height = width / aspect
                } else {
                    width = height * aspect
                }
                let maxWidth = left ? anchor.x : bounds.width - anchor.x
                let maxHeight = top ? anchor.y : bounds.height - anchor.y
                let shrink = min(1, maxWidth / width, maxHeight / height)
                width *= shrink
                height *= shrink
            } else {
                width = min(width, left ? anchor.x : bounds.width - anchor.x)
                height = min(height, top ? anchor.y : bounds.height - anchor.y)
            }
            rect = CGRect(x: left ? anchor.x - width : anchor.x, y: top ? anchor.y - height : anchor.y,
                          width: width, height: height)
        }
        return CGRect(x: rect.minX / image.width, y: rect.minY / image.height,
                      width: rect.width / image.width, height: rect.height / image.height)
    }

    /// 换比例：以当前框中心为准，取图片内能放下的最大框
    static func fit(ratio: CGFloat, around crop: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return crop }
        // 在像素比例下算（归一化坐标的宽高比 ≠ 实际比例）
        var width = imageSize.width
        var height = width / ratio
        if height > imageSize.height {
            height = imageSize.height
            width = height * ratio
        }
        let center = CGPoint(x: crop.midX * imageSize.width, y: crop.midY * imageSize.height)
        let x = min(max(center.x - width / 2, 0), imageSize.width - width)
        let y = min(max(center.y - height / 2, 0), imageSize.height - height)
        return CGRect(x: x / imageSize.width, y: y / imageSize.height,
                      width: width / imageSize.width, height: height / imageSize.height)
    }
}
