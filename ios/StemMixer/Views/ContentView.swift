import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: LibraryViewModel

    var body: some View {
        NavigationStack {
            LibraryView()
                .sheet(item: $library.selectedSong) { song in
                    MixerSheet(song: song)
                }
        }
        .tint(.white)
    }
}

// Wrapper that creates a fresh MixerViewModel per song
struct MixerSheet: View {
    let song: Song
    @StateObject private var vm: MixerViewModel

    init(song: Song) {
        self.song = song
        _vm = StateObject(wrappedValue: MixerViewModel(song: song))
    }

    var body: some View {
        MixerView()
            .environmentObject(vm)
    }
}
