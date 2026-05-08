import Foundation
import Combine
import AVFoundation

@MainActor
final class MixerViewModel: ObservableObject {
    @Published var song: Song
    @Published var mixerState: MixerState
    @Published var presets: [MixerPreset] = []
    @Published var isLoaded = false
    @Published var loadError: String?

    let audio = AudioEngine()
    private let db = LibraryService.shared

    init(song: Song) {
        self.song = song
        var state = MixerState()
        state.reset(stemNames: song.stemNames)
        self.mixerState = state
        loadPresets()
    }

    // MARK: - Loading

    func loadAudio() {
        Task { await _loadAudio() }
    }

    private func _loadAudio() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var urls: [String: URL] = [:]
        for (name, relativePath) in song.stems {
            let url = docs.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            urls[name] = url
        }
        do {
            try audio.loadStems(urls: urls)
            isLoaded = true
            // Restore saved state from DB (bpm may differ, just apply current state)
            applyMixerStateToEngine()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Controls

    func setVolume(_ v: Float, for stem: String) {
        mixerState.stems[stem]?.volume = v
        audio.setVolume(mixerState.effectiveVolume(for: stem), for: stem)
    }

    func setPan(_ p: Float, for stem: String) {
        mixerState.stems[stem]?.pan = p
        audio.setPan(p, for: stem)
    }

    func toggleMute(_ stem: String) {
        mixerState.stems[stem]?.muted.toggle()
        reapplyAll()
    }

    func toggleSolo(_ stem: String) {
        mixerState.stems[stem]?.soloed.toggle()
        reapplyAll()
    }

    func setMasterVolume(_ v: Float) {
        mixerState.masterVolume = v
        audio.setMasterVolume(v)
    }

    func toggleLoop() {
        audio.looping.toggle()
    }

    var isLooping: Bool { audio.looping }

    // MARK: - Presets

    func savePreset(name: String) {
        let preset = MixerPreset(songId: song.id, name: name,
                                 state: mixerState, createdAt: Date())
        db.savePreset(preset)
        loadPresets()
    }

    func loadPreset(_ preset: MixerPreset) {
        mixerState = preset.state
        applyMixerStateToEngine()
    }

    func deletePreset(_ preset: MixerPreset) {
        db.deletePreset(id: preset.id)
        loadPresets()
    }

    func loadPresets() {
        presets = db.fetchPresets(for: song.id)
    }

    // MARK: - Stem export

    func exportURL(for stem: String) -> URL? {
        guard let relativePath = song.stems[stem] else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(relativePath)
    }

    // MARK: - Private

    private func applyMixerStateToEngine() {
        audio.setMasterVolume(mixerState.masterVolume)
        for name in song.stemNames {
            if let ch = mixerState.stems[name] {
                audio.setVolume(mixerState.effectiveVolume(for: name), for: name)
                audio.setPan(ch.pan, for: name)
            }
        }
    }

    private func reapplyAll() {
        for name in song.stemNames {
            audio.setVolume(mixerState.effectiveVolume(for: name), for: name)
        }
    }
}
