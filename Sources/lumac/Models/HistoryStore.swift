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
    /// What was moved and where it landed, so the operation can be reversed.
    ///
    /// Absent on records written before this existed, and on operations that
    /// have nothing to put back: 系统优化 deletes nothing, and the part of an
    /// uninstall that mo carries out is trashed by mo, which never tells lumac
    /// where it put things.
    var moves: [Trash.Move]?
    /// Set once the moves have been put back.
    var undoneAt: Date?

    /// Whether the 撤销 button applies. Whether the files are still *there* is a
    /// separate question, answered when the restore actually runs.
    var canUndo: Bool { undoneAt == nil && !(moves ?? []).isEmpty }
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
    func add(command: String, freedBytes: Int64, itemCount: Int,
             note: String? = nil, moves: [Trash.Move] = []) {
        records.insert(HistoryRecord(command: command, date: Date(),
                                     freedBytes: freedBytes, itemCount: itemCount,
                                     note: note, moves: moves.isEmpty ? nil : moves),
                       at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
        save()
    }

    /// Puts one operation's files back. Returns what happened, for the message.
    ///
    /// The record is only marked undone when something actually came back — a
    /// Trash that has since been emptied leaves nothing to restore, and marking
    /// it anyway would claim a rollback that never occurred.
    func undo(_ record: HistoryRecord) async -> Trash.RestoreResult {
        let result = await Trash.restore(record.moves ?? [])
        guard !result.restored.isEmpty,
              let index = records.firstIndex(where: { $0.id == record.id }) else { return result }
        records[index].undoneAt = Date()
        save()
        return result
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
