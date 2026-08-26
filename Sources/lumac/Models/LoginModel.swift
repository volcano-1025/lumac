import SwiftUI
import Observation

/// Backs 启动项. Reads launchd agents/daemons natively (there is no `mo` command
/// for them) and toggles the user-domain ones, which need no elevated rights.
@MainActor
@Observable
final class LoginModel {
    var items: [LoginItem] = []
    var loading = false

    private var task: Task<Void, Never>?

    func loadIfNeeded() {
        guard items.isEmpty, !loading else { return }
        reload()
    }

    func reload() {
        task?.cancel()
        loading = true
        task = Task {
            let items = await Task.detached { LoginScanner.scan() }.value
            guard !Task.isCancelled else { return }
            self.items = items
            self.loading = false
        }
    }

    /// Flips a user agent's enabled state, persisting it for the next login.
    func toggle(_ item: LoginItem) {
        guard item.domain.togglable,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let newDisabled = !item.disabled
        // Reflect the change immediately; revert if launchctl refused it.
        items[index].disabled = newDisabled
        Task {
            let ok = await Task.detached { LoginScanner.setDisabled(item, newDisabled) }.value
            if !ok, let i = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[i].disabled = item.disabled
            }
        }
    }
}
