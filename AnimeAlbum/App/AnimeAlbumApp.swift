import SwiftData
import SwiftUI

@main
struct AnimeAlbumApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Photo.self, Album.self, AlbumEntry.self)
        } catch {
            fatalError("无法初始化数据库: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
