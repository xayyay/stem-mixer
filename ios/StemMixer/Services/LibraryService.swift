import Foundation
import SQLite3

final class LibraryService {
    static let shared = LibraryService()
    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTables()
    }

    // MARK: - Setup

    private func openDatabase() {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library.db")
        sqlite3_open(url.path, &db)
    }

    private func createTables() {
        let songsDDL = """
        CREATE TABLE IF NOT EXISTS songs (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            added_at REAL NOT NULL,
            last_opened REAL,
            play_count INTEGER NOT NULL DEFAULT 0,
            duration REAL NOT NULL DEFAULT 0,
            stems_json TEXT NOT NULL DEFAULT '{}',
            bpm REAL,
            thumbnail BLOB,
            model TEXT NOT NULL DEFAULT 'htdemucs',
            source_filename TEXT NOT NULL DEFAULT ''
        );
        """
        let presetsDDL = """
        CREATE TABLE IF NOT EXISTS presets (
            id TEXT PRIMARY KEY,
            song_id TEXT NOT NULL,
            name TEXT NOT NULL,
            state_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY(song_id) REFERENCES songs(id) ON DELETE CASCADE
        );
        """
        exec(songsDDL)
        exec(presetsDDL)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: - Songs CRUD

    func insertSong(_ song: Song) {
        let sql = """
        INSERT OR REPLACE INTO songs
          (id,title,artist,added_at,last_opened,play_count,duration,stems_json,bpm,thumbnail,model,source_filename)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let stemsJSON = (try? JSONEncoder().encode(song.stems)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        sqlite3_bind_text(stmt, 1, song.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, song.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, song.artist, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, song.addedAt.timeIntervalSince1970)
        if let lo = song.lastOpened {
            sqlite3_bind_double(stmt, 5, lo.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, Int32(song.playCount))
        sqlite3_bind_double(stmt, 7, song.duration)
        sqlite3_bind_text(stmt, 8, stemsJSON, -1, SQLITE_TRANSIENT)
        if let bpm = song.bpm {
            sqlite3_bind_double(stmt, 9, bpm)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let thumb = song.thumbnailData {
            thumb.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 10, ptr.baseAddress, Int32(thumb.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        sqlite3_bind_text(stmt, 11, song.model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 12, song.sourceFilename, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func updateSong(_ song: Song) { insertSong(song) }

    func deleteSong(id: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM songs WHERE id=?;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func fetchAllSongs(sortBy: SortOption = .addedAt) -> [Song] {
        let orderClause: String
        switch sortBy {
        case .addedAt:    orderClause = "added_at DESC"
        case .lastOpened: orderClause = "COALESCE(last_opened, added_at) DESC"
        case .playCount:  orderClause = "play_count DESC"
        case .title:      orderClause = "title ASC"
        case .duration:   orderClause = "duration DESC"
        }
        let sql = "SELECT * FROM songs ORDER BY \(orderClause);"
        return query(sql)
    }

    func search(query: String) -> [Song] {
        let pattern = "%\(query)%"
        let sql = "SELECT * FROM songs WHERE title LIKE ? OR artist LIKE ? ORDER BY added_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, pattern, -1, SQLITE_TRANSIENT)
        return rows(from: stmt)
    }

    func incrementPlayCount(id: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE songs SET play_count=play_count+1, last_opened=? WHERE id=?;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func updateBPM(id: String, bpm: Double) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE songs SET bpm=? WHERE id=?;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, bpm)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Presets

    func savePreset(_ preset: MixerPreset) {
        let stateJSON = (try? JSONEncoder().encode(preset.state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sql = "INSERT OR REPLACE INTO presets (id,song_id,name,state_json,created_at) VALUES (?,?,?,?,?);"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, preset.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, preset.songId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, preset.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, stateJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, preset.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func fetchPresets(for songId: String) -> [MixerPreset] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT * FROM presets WHERE song_id=? ORDER BY created_at DESC;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, songId, -1, SQLITE_TRANSIENT)
        var result: [MixerPreset] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let songId = String(cString: sqlite3_column_text(stmt, 1))
            let name = String(cString: sqlite3_column_text(stmt, 2))
            let stateJSON = String(cString: sqlite3_column_text(stmt, 3))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            if let stateData = stateJSON.data(using: .utf8),
               let state = try? JSONDecoder().decode(MixerState.self, from: stateData) {
                result.append(MixerPreset(id: id, songId: songId, name: name, state: state, createdAt: createdAt))
            }
        }
        return result
    }

    func deletePreset(id: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM presets WHERE id=?;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Private helpers

    private func query(_ sql: String) -> [Song] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        return rows(from: stmt)
    }

    private func rows(from stmt: OpaquePointer?) -> [Song] {
        var songs: [Song] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let song = songFromRow(stmt) { songs.append(song) }
        }
        return songs
    }

    private func songFromRow(_ stmt: OpaquePointer?) -> Song? {
        guard let stmt else { return nil }
        let id        = String(cString: sqlite3_column_text(stmt, 0))
        let title     = String(cString: sqlite3_column_text(stmt, 1))
        let artist    = String(cString: sqlite3_column_text(stmt, 2))
        let addedAt   = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let lastOpened: Date? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)) : nil
        let playCount = Int(sqlite3_column_int(stmt, 5))
        let duration  = sqlite3_column_double(stmt, 6)
        let stemsJSON = String(cString: sqlite3_column_text(stmt, 7))
        let bpm: Double? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? sqlite3_column_double(stmt, 8) : nil
        let thumbBytes = sqlite3_column_bytes(stmt, 9)
        let thumbnail: Data? = thumbBytes > 0
            ? Data(bytes: sqlite3_column_blob(stmt, 9), count: Int(thumbBytes)) : nil
        let model  = String(cString: sqlite3_column_text(stmt, 10))
        let source = String(cString: sqlite3_column_text(stmt, 11))

        let stems = (stemsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]

        return Song(id: id, title: title, artist: artist, addedAt: addedAt,
                    lastOpened: lastOpened, playCount: playCount, duration: duration,
                    stems: stems, bpm: bpm, thumbnailData: thumbnail,
                    model: model, sourceFilename: source)
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case addedAt, lastOpened, playCount, title, duration
    var id: String { rawValue }
    var label: String {
        switch self {
        case .addedAt:    return "Date Added"
        case .lastOpened: return "Last Opened"
        case .playCount:  return "Most Played"
        case .title:      return "Title"
        case .duration:   return "Duration"
        }
    }
}

// Satisfy Sendable for SQLite raw pointer passing
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
