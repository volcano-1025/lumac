import SwiftUI
import Observation

/// Backs the 扫描与白名单 settings: the project directories `mo purge` scans and
/// the paths `mo clean` protects. Each edit writes straight back to the mole
/// config files so the next run picks it up.
@MainActor
@Observable
final class ConfigModel {
    var purgePaths: [String] = []
    var whitelist: [String] = []
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        purgePaths = MoleConfig.readPurgePaths()
        whitelist = MoleConfig.readWhitelist()
    }

    // MARK: - Purge scan paths

    func addPurgePath(_ path: String) {
        let entry = MoleConfig.tildify(path)
        guard !purgePaths.contains(entry) else { return }
        purgePaths.append(entry)
        MoleConfig.writePurgePaths(purgePaths)
    }

    func removePurgePath(_ entry: String) {
        purgePaths.removeAll { $0 == entry }
        MoleConfig.writePurgePaths(purgePaths)
    }

    // MARK: - Clean whitelist

    func addWhitelist(_ path: String) {
        let entry = MoleConfig.tildify(path)
        guard !whitelist.contains(entry) else { return }
        whitelist.append(entry)
        MoleConfig.writeWhitelist(whitelist)
    }

    func removeWhitelist(_ entry: String) {
        whitelist.removeAll { $0 == entry }
        MoleConfig.writeWhitelist(whitelist)
    }
}
