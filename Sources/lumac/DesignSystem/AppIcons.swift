import SwiftUI
import AppKit

/// Application icons for the process list.
///
/// `NSWorkspace.icon(forFile:)` reads from disk, so results are cached: the HUD
/// re-renders on every two second poll and would otherwise hit the file system
/// a dozen times a second.
@MainActor
enum AppIcons {
    private static var cache: [String: Image] = [:]

    /// The icon for an application bundle, or nil for daemons and other
    /// executables that live outside one.
    static func icon(forBundle path: String?) -> Image? {
        guard let path else { return nil }
        if let cached = cache[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let nsImage = NSWorkspace.shared.icon(forFile: path)
        nsImage.size = NSSize(width: 32, height: 32)
        let image = Image(nsImage: nsImage)
        cache[path] = image
        return image
    }
}
