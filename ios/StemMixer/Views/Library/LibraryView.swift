import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var showImportPicker = false
    @State private var showSortMenu = false
    @State private var editingSong: Song?

    // Supported audio/video types
    private let supportedTypes: [UTType] = [
        .audio, .mpeg4Audio, .mp3,
        UTType(mimeType: "audio/flac") ?? .audio,
        UTType(mimeType: "audio/ogg")  ?? .audio,
        .mpeg4Movie, .movie, .video
    ]

    var body: some View {
        ZStack {
            Color(hex: "#111111").ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                searchBar
                if vm.songs.isEmpty {
                    emptyState
                } else {
                    songList
                }
            }

            if vm.isSeparating {
                SeparationProgressOverlay()
            }
        }
        .navigationBarHidden(true)
        .onChange(of: vm.searchText) { _ in vm.refresh() }
        .onChange(of: vm.sortOption)  { _ in vm.refresh() }
        .fileImporter(isPresented: $showImportPicker,
                      allowedContentTypes: supportedTypes,
                      allowsMultipleSelection: false) { result in
            if let url = try? result.get().first {
                vm.importAndSeparate(url: url)
            }
        }
        .sheet(item: $editingSong) { song in
            EditSongSheet(song: song)
                .environmentObject(vm)
        }
        .alert("Error", isPresented: .constant(vm.separationError != nil)) {
            Button("OK") { vm.separationError = nil }
        } message: {
            Text(vm.separationError ?? "")
        }
    }

    // MARK: - Sub-views

    private var headerBar: some View {
        HStack {
            Text("Stem Mixer")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Spacer()
            Menu {
                ForEach(SortOption.allCases) { opt in
                    Button(opt.label) { vm.sortOption = opt }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
            }
            Button {
                showImportPicker = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: "#3ecfff"))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(hex: "#1a1a1a"))
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.gray)
            TextField("Search songs…", text: $vm.searchText)
                .foregroundStyle(.white)
                .autocorrectionDisabled()
        }
        .padding(10)
        .background(Color(hex: "#252525"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(hex: "#1a1a1a"))
    }

    private var songList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.songs) { song in
                    SongRow(song: song) {
                        vm.openSong(song)
                    } onEdit: {
                        editingSong = song
                    } onDelete: {
                        vm.deleteSong(song)
                    }
                    Divider().background(Color(hex: "#2a2a2a"))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundStyle(Color(hex: "#3ecfff").opacity(0.5))
            Text("No songs yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.6))
            Text("Tap + to import an audio or video file\nand separate it into stems.")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            if !StemSeparationService.shared.isModelAvailable {
                Text("⚠️ Demucs.mlpackage not found in bundle.\nAdd it after running convert_to_coreml.py.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
    }
}

// MARK: - Song row

struct SongRow: View {
    let song: Song
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                // Thumbnail or placeholder
                if let data = song.thumbnailData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable().scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "#2a2a2a"))
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(Color(hex: "#3ecfff"))
                        }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.body.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(formatDuration(song.duration))
                            .font(.caption)
                            .foregroundStyle(.gray)
                        if let bpm = song.bpm {
                            Text(String(format: "%.0f BPM", bpm))
                                .font(.caption)
                                .foregroundStyle(Color(hex: "#3ecfff").opacity(0.8))
                        }
                        Text(song.model)
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color(hex: "#252525"))
                            .foregroundStyle(.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.gray)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(hex: "#111111"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }.tint(.blue)
        }
    }
}

// MARK: - Edit sheet

struct EditSongSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel
    let song: Song
    @State private var title: String
    @State private var artist: String

    init(song: Song) {
        self.song = song
        _title  = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Metadata") {
                    TextField("Title",  text: $title)
                    TextField("Artist", text: $artist)
                }
                Section("Info") {
                    LabeledContent("Duration", value: formatDuration(song.duration))
                    if let bpm = song.bpm {
                        LabeledContent("BPM", value: String(format: "%.1f", bpm))
                    }
                    LabeledContent("Model", value: song.model)
                    LabeledContent("Stems", value: song.stemNames.joined(separator: ", "))
                }
            }
            .navigationTitle("Edit Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.updateMetadata(song: song, title: title, artist: artist)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Progress overlay

struct SeparationProgressOverlay: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView(value: vm.separationProgress)
                    .progressViewStyle(.linear)
                    .tint(Color(hex: "#3ecfff"))
                    .frame(maxWidth: 280)
                Text(vm.separationStatusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text(String(format: "%.0f%%", vm.separationProgress * 100))
                    .font(.title.bold())
                    .foregroundStyle(Color(hex: "#3ecfff"))
            }
            .padding(32)
            .background(Color(hex: "#1a1a1a"))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - Helpers

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}
