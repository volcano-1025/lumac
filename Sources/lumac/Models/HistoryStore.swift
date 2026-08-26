import Foundation
import Observation

/// lumac's own operation log.
///
/// `mo history` is the wrong source: it records every `--dry-run` *preview*
/// (which the app fires just to build a scan list) with a misleading "would
/// free" size, while lumac's real deletions go straight to the Trash and never
/// touch mo at all. So the app keeps its own record — one entry per operation it
/// actually carried out, with the bytes it actually freed.
struct HistoryRecord: Codable, Identifiable {
    var id = UUID()
    /// Raw command name: clean / purge / uninstall / optimize.
    var command: String
    var date: Date
    var freedBytes: Int64
    var itemCount: Int
    /// Optional detail — the uninstalled app's name, or the optimize summary.
    var note: String?
}

@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var records: [HistoryRecord] = []

    private let fileURL: URL
    private let cap = 100

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lumac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        self.records = records
    }

    /// Records one completed operation, newest first.
    func add(command: String, freedBytes: Int64, itemCount: Int, note: String? = nil) {
        records.insert(HistoryRecord(command: command, date: Date(),
                                     freedBytes: freedBytes, itemCount: itemCount, note: note),
                       at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
