# lumac

macOS 菜单栏系统监控 + 清理工具。图形前端,底层清理/扫描调用 `mo`(mole)命令行工具;
CPU/内存/磁盘/网络等实时指标由 app 原生读取(mach / IOKit / getifaddrs),不依赖 CLI。

## 怎么跑

```bash
./build.sh            # debug;release 用 ./build.sh release
open build/lumac.app
```

- 无需 Xcode:SwiftPM 编译二进制,`build.sh` 手工组装 .app bundle。
- 清理/软件等功能需要 `mo` 在 PATH 上(见 `MoCLI.searchPaths`);缺失时状态页仍可看,但会提示装 mo。
- SDK 固定在 26.5(见 build.sh 顶部注释:27.0 SDK 的 @State 宏缺 libSwiftUIMacros,需 Xcode)。
- **签名**:`build.sh` 优先用自签名身份 **`lumac-selfsign`** 签(钥匙串里有就用,没有回退 ad-hoc)。用它的原因:TCC(完全磁盘访问等授权)绑的是签名的**指定要求**,该身份的 DR 锚定证书哈希而非二进制哈希 → **授权跨重编译保留**;ad-hoc 每次编译哈希变会被当新 app 反复要授权。身份用 `./scripts/make-signing-cert.sh` 一次性创建(openssl 自签 codeSigning 证书导入 login 钥匙串)。自签名 Gatekeeper 不信任,**下载后首次打开需绕过一次**(右键打开 / `xattr -dr com.apple.quarantine`),但更新保留授权。要正式无摩擦分发需 Developer ID + 公证($99/年);改 build.sh 的 `LUMAC_SIGN_ID` 即可换身份。

## 技术栈

Swift 6 工具链 / 语言模式 v5 · SwiftUI · SwiftPM · macOS 26。无资源目录(no actool),
图片以散装 PNG 放在 `Resources/` 用 `Bundle.module` 读取。

## 目录

- `Sources/lumac/CLI/` — `mo` 封装(MoCLI)、原生指标(SystemStats/GPUStats/NetworkStats)、进程(ProcessLister)、清理(Trash/CleanParser/PurgeParser/InstallerScanner)、卸载扫描(AppScanner,原生枚举应用+残留)、优化解析(OptimizeParser)、启动项(LoginScanner,原生 launchd)、更新(Brew,brew outdated/upgrade)、权限(Permissions:完全磁盘访问检测 + LocalAuthentication Touch ID)、更新检查(UpdateChecker:mo 版本 vs GitHub release)、配置读写(MoleConfig:直接读写 `~/.config/mole/{purge_paths,whitelist}`)
- `Sources/lumac/Models/` — AppState(轮询与状态)、Status(mo JSON 解码)、Cleanup 系列、Analyze/AnalyzeModel(磁盘分析)、Uninstall/UninstallModel(卸载)、OptimizeModel、LoginModel、UpdatesModel、ConfigModel(扫描路径/白名单)、HistoryStore(lumac 自有操作记录)
- `Sources/lumac/Views/` — RootView(顶部胶囊导航 + FDA 横幅 + 引导 sheet)、StatusView(概览仪表盘)、CleanupView、UninstallView(卸载两步流)、OptimizeView(系统优化)、LoginView(启动项)、UpdatesView(应用更新)、AnalyzeView(磁盘分析)、HistoryView(操作记录)、SettingsView(设置)、OnboardingView(首启引导)、MenuBar + StatusItemView(菜单栏)
- `Sources/lumac/DesignSystem/` — Tokens(颜色/间距)、AppIcons
- `Tools/makelumac.swift` — 生成 app 图标(月牙)到 `Resources/appicon.png`
- `build.sh` — 编译 + 组装 `build/lumac.app`

## 约定与要点

- **命名**:全项目统一 **lumac** —— SwiftPM target / 可执行文件 / 模块 / `LumacApp` / 资源 bundle(`lumac_lumac.bundle`)都叫 lumac。已无 "Kiwi" 残留。
- 实时指标一律走原生 syscall,不用 `mo status`(它每次冷启动,速率/负载这类差值不可靠);`mo status` 只供健康评分、机型、电池、蓝牙、温度这些它专有的字段,2 秒一次;原生指标 1 秒一次。
- 进程列表只显示「真正的应用」:有 .app bundle 且非后台代理(`ProcessLister.isListed` / `isSystemAgent`,按 Info.plist 的 `LSBackgroundOnly` / `/System` 下的 `LSUIElement` 判定),外加 `listedSystemProcesses` 白名单(目前仅 WindowServer)。名字用 `FileManager.displayName` 取本地化名(访达 / 备忘录 …)。
- 注释解释「为什么」,与现有高密度注释风格保持一致。

## 当前状态

- 已从 Kiwi 彻底改名为 lumac(可见文案 + bundle + target/模块/`LumacApp` 全部)。
- 概览仪表盘:健康 | 网络/CPU/GPU · 电池/内存/磁盘 的等高网格 + 按内存排序的应用列表;菜单栏显示内存占用%(白/琥珀/红随占用)+ 上下行网速。
- **窗口生命周期**:点窗口 X(关主窗)→ `AppDelegate` 监听 `NSWindow.willCloseNotification`(按 `identifier=="main"` 认主窗)→ `setActivationPolicy(.accessory)`,收成纯菜单栏挂件(无 Dock 图标),app 不退(`applicationShouldTerminateAfterLastWindowClosed=false`);菜单栏 HUD「打开 lumac」→ `app.openMainWindow()`(切回 `.regular` + `reopenWindow` 用 `openWindow(id:"main")` 重开);HUD「退出」→ `NSApp.terminate` 全退。`app.mainWindow` 弱引用 + `reopenWindow` 闭包在 RootView.onAppear 里挂。
- 深度清理(clean)走通:dry-run 扫描 → 逐项勾选 → 移废纸篓;安装包并入 clean 页作不勾选行。
- 项目产物(purge):`mo purge --dry-run` 输出无清单文件、直接打印路径,`PurgeParser` 解析 stdout(`✓ [DRY RUN] <path>, <size>`)→ 复用 CleanupModel/Trash 流程;已加入 软件区 switcher(Screen.purge / CleanupCommand.scanStrategy=.purgeStdout)。
- 卸载应用(uninstall):**不走 mo,纯原生**(`AppScanner`)。原因:`mo uninstall --list` 有 bug——非 TTY 时 exit 1、只输出 18/58 个应用且 JSON 缺结尾 `]`;`mo uninstall --dry-run <app>` 每次全盘扫残留要 ~45s。改为原生枚举 `/Applications`(+Utilities +~/Applications)读 Info.plist,残留按 bundleId 扫标准 Library 位置(App Support/Caches/Preferences/HTTPStorages/WebKit/Containers/Group Containers…),秒出且完整。列表可按 大小/最近使用(Spotlight `kMDItemLastUsedDate`)/名称 排序 + 搜索。执行:app bundle + 用户空间残留移废纸篓;`/Library` 下的 LaunchDaemons/PrivilegedHelperTools 等标 `reviewOnly`,仅展示不删(需提权,留待 Touch ID)。两步视图 UninstallView,路由在 SoftwareSection 里先于通用 cleanup 分流。
- 系统优化(optimize):`mo optimize --dry-run` 预览维护项 → `mo optimize` 执行(实测非交互、不弹 sudo、需权限的任务自动跳过,不会卡住)。`OptimizeParser` 解析 `➤ 类目 / ✓→◎ 动作` + 汇总行。不删个人文件,自有视图 OptimizeView(在 RootView 里 optimize 先于通用 cleanup 分流)。
- 启动项(login):**无 mo 命令,纯原生**。`LoginScanner` 读 `~/Library/LaunchAgents`(用户)+ `/Library/LaunchAgents`、`/Library/LaunchDaemons`(系统)的 plist(Label/Program),用 `launchctl print-disabled gui/<uid>` 判断开关态。**只有用户级** agent 可切换:`launchctl enable/disable gui/<uid>/<label>`(无需 sudo,下次登录生效);系统级只读、标锁。
- 启动时检查更新:`UpdateChecker` 每次启动(引导完成后)后台查一次 **mole CLI** 更新——`mo --version` 对比 GitHub `tw93/Mole` 最新 release tag(去 v/V 前缀,数值逐段比 semver),有新版弹 alert(可「用 Homebrew 更新」跑 `brew upgrade mole` 或终端 `mo update`)。**lumac 本身不查**——无发布渠道(用户选定只查 mole)。
- 应用更新(updates):**无 mo 命令**。本机只有 `brew`(无 `mas`/Sparkle),故只覆盖 Homebrew。`Brew.outdated` 解析 `brew outdated --json=v2`(cask=应用在前,formula=命令行在后),`brew upgrade [--cask] <name>` 更新。无 TTY 时 sudo 会即时失败而非卡住,所以从 GUI 跑是安全的。页面明说「只覆盖 Homebrew 管理的应用」。
- 磁盘分析(`mo analyze -json`):面包屑下钻 + 按目录/大文件切换 + 访达显示 + 单文件移废纸篓(带确认)。
- 操作记录:**不用 `mo history`**——mo 的历史会把 `--dry-run` 预览(打开扫描页就会触发)记进去、还带误导性的「would free」体积,且 lumac 真正的删除是自己移废纸篓、根本不经过 mo。改为 `HistoryStore` 自记账,存 `~/Library/Application Support/lumac/history.json`,只在真正执行(clean/purge/uninstall/optimize)后记一条真实释放量。老数据不迁移,新装从空开始。
- 设置:**居中弹窗 sheet**(不是内容页;品牌菜单点「设置」开 `app.showingSettings`,固定 600×680 带标题栏+完成),内含 主题、危险操作确认、底部状态条(均真实生效)+ 扫描与白名单(直接读写 `~/.config/mole/{purge_paths,whitelist}`,`# 头注释 + 空行 + 每行一路径`,NSOpenPanel 选目录、`~` 化)+ 权限与安全(完全磁盘访问状态/去开启、Touch ID 确认开关、重看引导)+ 关于(mo 检测/版本/废纸篓/检查更新)。mo 的 `--paths`/`--whitelist` 是交互 TUI(非 TTY 会卡住),故绕开直接写文件。
- **权限与引导(阶段 3)**:首启 `OnboardingView`(欢迎→完全磁盘访问→Touch ID/完成),`didOnboard` 存 UserDefaults;`FullDiskAccess.granted` 用能否读 `~/Library/Application Support/com.apple.TCC` 判断(慢轮询刷新 `app.fdaGranted`),未授权时 RootView 顶部常驻红色横幅;Touch ID 走 `LocalAuthentication` 的 `.deviceOwnerAuthentication`(`requireBiometric` 开时,清理/卸载执行前 `app.confirmBiometric` 拦一道,失败/取消不执行;设备不支持则放行)。
- **Trash 安全护栏**:`Trash.isDeletable` 原本要求路径 ≥3 段(挡住 `/Applications` 等根),为卸载放开了唯一例外——**顶层 `/Applications/*.app`**(正好 2 段,`.app` 结尾);`/Applications` 目录本身仍被 `forbiddenRoots` 挡住,嵌套路径仍走 ≥3 段规则。改这里要非常小心。
- **未完成**:通知中心提醒(本 app ad-hoc 签名,UNUserNotificationCenter 注册可能不稳,按需求暂不做);首启第三步「自动清理频率」未做。
- **能力边界(设计使然,非缺陷)**:`installer` 交互 TUI 无清单文件 → 已在 clean 内用原生 `InstallerScanner` 覆盖,无独立页;卸载的 `/Library` 系统项(LaunchDaemons/PrivilegedHelperTools)需 root,本 app ad-hoc 签名做不了签名版特权 helper(SMJobBless),故只展示不删——Touch ID 在这里是**操作确认门**不是提权;更新只覆盖 Homebrew(无 `mas`/Sparkle);启动项只覆盖 launchd agent/daemon(不含 BTM「打开时登录」项,需 `sfltool`/提权)。
- 所有主要页面均已实现,无 `尚未实现` 占位(PlaceholderView 仅作兜底)。
- 无 git 版本控制;删除不可逆,谨慎。
