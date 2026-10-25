import SwiftData
import SwiftUI

@main
struct AnimeAlbumApp: App {
    let container: ModelContainer
    @State private var commandCenter = AppCommandCenter()

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
                .environment(commandCenter)
        }
        .modelContainer(container)
        .commands { AppCommands(center: commandCenter) }
    }
}
