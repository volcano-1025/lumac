import Foundation

/// Chinese translations for `mo optimize`'s English category titles and action
/// lines. The category set is fixed; the action lines are mostly fixed too, with
/// a few that embed a count, size or app name — handled by pattern.
enum OptimizeText {

    static func title(_ english: String) -> String {
        titles[english] ?? english
    }

    static func detail(_ english: String) -> String {
        if let exact = details[english] { return exact }
        for (pattern, template) in patterns {
            if let translated = apply(pattern, template, to: english) { return translated }
        }
        return english
    }

    // MARK: - Titles

    private static let titles: [String: String] = [
        "DNS & Spotlight Check": "DNS 与 Spotlight 检查",
        "Finder Cache Refresh": "访达缓存刷新",
        "App State Cleanup": "应用状态清理",
        "Broken Config Repair": "损坏配置修复",
        "Network Cache Refresh": "网络缓存刷新",
        "Database Optimization": "数据库优化",
        "LaunchServices Repair": "启动服务修复",
        "Prevent Finder .DS_Store": "阻止访达生成 .DS_Store",
        "Legacy Overrides": "遗留覆盖项",
        "Network Stack Refresh": "网络栈刷新",
        "Permission Repair": "权限修复",
        "Spotlight Optimization": "Spotlight 优化",
        "Spotlight Orphan Rules": "Spotlight 冗余规则",
        "Periodic Maintenance": "周期性维护",
        "Shared File Lists": "共享文件列表",
        "Disk Health": "磁盘健康",
        "Login Items": "登录项",
        "Quarantine Database Cleanup": "隔离数据库清理",
        "Launch Agents Cleanup": "启动代理清理",
        "Notifications": "通知",
        "Usage Data": "使用数据",
        "Performance Diagnosis": "性能诊断",
    ]

    // MARK: - Action lines (exact)

    private static let details: [String: String] = [
        "DNS cache flushed": "DNS 缓存已刷新",
        "Spotlight index verified": "Spotlight 索引已校验",
        "QuickLook thumbnails refreshed": "QuickLook 缩略图已刷新",
        "Icon services cache rebuilt": "图标服务缓存已重建",
        "App saved states optimized": "应用保存状态已优化",
        "All preference files valid": "所有偏好设置文件正常",
        "DNS cache already refreshed": "DNS 缓存已是最新",
        "mDNSResponder already restarted": "mDNSResponder 已重启",
        "No databases found to optimize": "没有需要优化的数据库",
        "LaunchServices repaired": "启动服务已修复",
        "File associations refreshed": "文件关联已刷新",
        ".DS_Store prevention already enabled on network & USB volumes": "已在网络与 USB 卷上启用 .DS_Store 阻止",
        "No legacy App Nap or disk-image overrides found": "未发现遗留的 App Nap 或磁盘映像覆盖",
        "Network stack refresh skipped, active VPN detected": "检测到活动 VPN，已跳过网络栈刷新",
        "User directory permissions already optimal": "用户目录权限已最优",
        "Spotlight index already optimal": "Spotlight 索引已最优",
        "Spotlight search rules already clean": "Spotlight 搜索规则已整洁",
        "Failed to scan shared file lists": "扫描共享文件列表失败",
        "Launch Agents all healthy": "启动代理全部正常",
        "Quarantine database already clean": "隔离数据库已整洁",
        "No sustained high-CPU bottleneck detected": "未检测到持续的高 CPU 瓶颈",
        "Periodic maintenance skipped (not available on this macOS version)": "已跳过周期性维护（当前 macOS 版本不支持）",
        "Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)": "已跳过磁盘校验（设置 MOLE_ENABLE_DISK_VERIFY=1 启用）",
    ]

    // MARK: - Action lines (with a variable piece)

    /// (regex, template). `$1` in the template is the captured group.
    private static let patterns: [(String, String)] = [
        (#"^Close these apps before database optimization: (.+)$"#, "优化数据库前请先关闭：$1"),
        (#"^Login items all healthy \((\d+) checked\)$"#, "登录项全部正常（已检查 $1 个）"),
        (#"^Notification Center database is healthy \((.+)\)$"#, "通知中心数据库正常（$1）"),
        (#"^Knowledge database is healthy \((.+)\)$"#, "知识库数据库正常（$1）"),
    ]

    private static func apply(_ pattern: String, _ template: String, to text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else { return nil }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
