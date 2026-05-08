import Foundation

struct StemChannel: Codable, Equatable {
    var volume: Float = 1.0   // 0..1
    var pan: Float = 0.0      // -1..1
    var muted: Bool = false
    var soloed: Bool = false
}

struct MixerState: Codable, Equatable {
    var stems: [String: StemChannel] = [:]
    var masterVolume: Float = 1.0

    mutating func reset(stemNames: [String]) {
        stems = Dictionary(uniqueKeysWithValues: stemNames.map { ($0, StemChannel()) })
        masterVolume = 1.0
    }

    var hasSolo: Bool { stems.values.contains { $0.soloed } }

    func effectiveVolume(for name: String) -> Float {
        guard let ch = stems[name] else { return 1 }
        if ch.muted { return 0 }
        if hasSolo && !ch.soloed { return 0 }
        return ch.volume
    }
}

struct MixerPreset: Identifiable, Codable {
    var id: String = UUID().uuidString
    var songId: String
    var name: String
    var state: MixerState
    let createdAt: Date
}
