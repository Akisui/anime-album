import PDFKit
import SwiftUI

/// PDF 阅读器（DESIGN.md §8.3 V3）：按页左右翻、双指缩放。与照片查看器分开 ——
/// 查看器的过渡 / 沉浸逻辑按单张图片设计，PDF 需要的是分页阅读
struct PDFReaderView: View {
    let photo: Photo

    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex = 0
    @State private var document: PDFDocument?

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFPagesView(document: document, pageIndex: $pageIndex)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("无法打开 PDF", systemImage: "doc.questionmark")
                }
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle(photo.originalFilename ?? "PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("分享", systemImage: "square.and.arrow.up") {
                        PhotoSharing.share([photo])
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let document, document.pageCount > 1 {
                    Text("\(pageIndex + 1) / \(document.pageCount)")
                        .font(.footnote.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
        }
        .task {
            document = PDFDocument(url: ImageStore.shared.url(forRelativePath: photo.fileRelativePath))
            #if DEBUG
            // 调试：PDF_PAGE=n 打开后翻到第 n 页（验证翻页与页码）
            if let raw = ProcessInfo.processInfo.environment["PDF_PAGE"], let page = Int(raw) {
                try? await Task.sleep(for: .seconds(0.8))
                pageIndex = page
            }
            #endif
        }
    }
}

/// PDFView 桥接：单页、横向翻页（页面控制器），页码与 SwiftUI 双向同步
private struct PDFPagesView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = .secondarySystemBackground
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.document = document
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.pageIndex = $pageIndex
        guard let page = document.page(at: pageIndex), view.currentPage != page else { return }
        view.go(to: page)
    }

    final class Coordinator: NSObject {
        var pageIndex: Binding<Int>
        private var observer: NSObjectProtocol?

        init(pageIndex: Binding<Int>) {
            self.pageIndex = pageIndex
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                guard let self, let view, let page = view.currentPage, let document = view.document else { return }
                let index = document.index(for: page)
                if self.pageIndex.wrappedValue != index {
                    self.pageIndex.wrappedValue = index
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
