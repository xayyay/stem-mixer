import SwiftUI

@main
struct StemMixerApp: App {
    @StateObject private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}
