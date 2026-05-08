import Foundation

struct Song: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var artist: String
    let addedAt: Date
    var lastOpened: Date?
    var playCount: Int
    var duration: Double            // seconds
    var stems: [String: String]     // stemName -> relative path from Documents
    var bpm: Double?
    var thumbnailData: Data?
    var model: String               // e.g. "htdemucs", "htdemucs_6s"
    var sourceFilename: String

    static func == (lhs: Song, rhs: Song) -> Bool { lhs.id == rhs.id }

    var stemNames: [String] {
        let order = ["drums", "bass", "vocals", "guitar", "piano", "other"]
        return order.filter { stems.keys.contains($0) }
    }
}
