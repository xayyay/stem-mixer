import Foundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var songs: [Song] = []
    @Published var searchText = ""
    @Published var sortOption: SortOption = .addedAt
    @Published var selectedSong: Song?
    @Published var showingImporter = false
    @Published var isSeparating = false
    @Published var separationProgress: Double = 0
    @Published var separationError: String?
    @Published var separationStatusMessage = ""

    private let db = LibraryService.shared

    init() { refresh() }

    func refresh() {
        if searchText.isEmpty {
            songs = db.fetchAllSongs(sortBy: sortOption)
        } else {
            songs = db.search(query: searchText)
        }
    }

    func deleteSong(_ song: Song) {
        // Remove stems from disk
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stemDir = docs.appendingPathComponent("stems/\(song.id)")
        try? FileManager.default.removeItem(at: stemDir)
        db.deleteSong(id: song.id)
        refresh()
        if selectedSong?.id == song.id { selectedSong = nil }
    }

    func openSong(_ song: Song) {
        db.incrementPlayCount(id: song.id)
        selectedSong = song
    }

    func updateMetadata(song: Song, title: String, artist: String) {
        var updated = song
        updated.title  = title.trimmingCharacters(in: .whitespaces).isEmpty ? song.title : title
        updated.artist = artist
        db.updateSong(updated)
        refresh()
        if selectedSong?.id == song.id { selectedSong = updated }
    }

    // MARK: - Import & separate

    func importAndSeparate(url: URL) {
        Task { await _importAndSeparate(url: url) }
    }

    private func _importAndSeparate(url: URL) async {
        isSeparating = true
        separationProgress = 0
        separationError = nil
        separationStatusMessage = "Loading audio…"

        let service = StemSeparationService.shared

        do {
            // Access security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // Copy to temp location
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: url, to: tempURL)

            let songId = UUID().uuidString
            let docs   = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let stemDir = docs.appendingPathComponent("stems/\(songId)")

            separationStatusMessage = "Separating stems (this may take several minutes)…"

            let stemURLs = try await service.separate(audioURL: tempURL, outputDir: stemDir) { [weak self] p in
                self?.separationProgress = p
                self?.separationStatusMessage = String(format: "Separating… %.0f%%", p * 100)
            }

            separationStatusMessage = "Detecting BPM…"
            let drumsURL = stemURLs["drums"]
            let bpm: Double? = drumsURL.flatMap { BPMDetector.detect(from: $0) }

            // Compute duration from first stem
            let dur: Double
            if let firstURL = stemURLs.values.first,
               let af = try? AVAudioFile(forReading: firstURL) {
                dur = Double(af.length) / af.processingFormat.sampleRate
            } else {
                dur = 0
            }

            // Relative paths for storage
            var relativePaths: [String: String] = [:]
            for (name, stemURL) in stemURLs {
                relativePaths[name] = "stems/\(songId)/\(stemURL.lastPathComponent)"
            }

            let title = url.deletingPathExtension().lastPathComponent
            let song = Song(
                id: songId, title: title, artist: "",
                addedAt: Date(), lastOpened: nil, playCount: 0,
                duration: dur, stems: relativePaths, bpm: bpm,
                thumbnailData: nil, model: "htdemucs",
                sourceFilename: url.lastPathComponent
            )
            db.insertSong(song)
            try? FileManager.default.removeItem(at: tempURL)
            refresh()
            separationStatusMessage = "Done!"
        } catch {
            separationError = error.localizedDescription
        }

        isSeparating = false
    }
}
