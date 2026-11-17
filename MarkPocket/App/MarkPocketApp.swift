import SwiftUI

@main
struct MarkPocketApp: App {
    @State private var library = DocumentLibraryStore()
    @State private var preferences = ReaderPreferences()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library, preferences: preferences)
                .onOpenURL { url in
                    Task {
                        _ = await library.importExternalFileAsync(from: url, openImmediately: true)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        library.rescanLocalDocuments()
                    }
                }
        }
    }
}
