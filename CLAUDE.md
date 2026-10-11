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

- `Sources/lumac/CLI/` — `mo` 封装(MoCLI)、原生指标(SystemStats/GPUStats/NetworkStats)、进程(ProcessLister)、清理(Trash/CleanParser/PurgeParser/InstallerScanner)、卸载扫描(AppScanner,原生枚举应用+残留)、优化解析(OptimizeParser + OptimizeText 中文映射)、更新(Brew,brew outdated/upgrade,走注入的国内镜像 + 进程超时)、权限(Permissions:完全磁盘访问检测 + LocalAuthentication Touch ID)、更新检查(UpdateChecker:lumac 与 mole 各自版本 vs GitHub release)、配置读写(MoleConfig:直接读写 `~/.config/mole/{purge_paths,whitelist}`)
- `Sources/lumac/Models/` — AppState(轮询与状态)、Status(mo JSON 解码)、Cleanup 系列、Analyze/AnalyzeModel(磁盘分析)、Uninstall/UninstallModel(卸载)、OptimizeModel、UpdatesModel、ConfigModel(扫描路径/白名单)、HistoryStore(lumac 自有操作记录)
- `Sources/lumac/Views/` — RootView(顶部胶囊导航 + FDA 横幅 + 引导 sheet)、StatusView(概览仪表盘)、CleanupView、UninstallView(卸载两步流)、OptimizeView(系统优化)、UpdatesView(应用更新)、AnalyzeView(磁盘分析)、HistoryView(操作记录)、SettingsView(设置)、OnboardingView(首启引导)、MenuBar + StatusItemView(菜单栏)
- `Sources/lumac/DesignSystem/` — Tokens(颜色/间距)、AppIcons
- `Tools/makelumac.swift` — 生成 app 图标(月牙)到 `Resources/appicon.png`
- `build.sh` — 编译 + 组装 `build/lumac.app`

## 约定与要点

- **命名**:全项目统一 **lumac** —— SwiftPM target / 可执行文件 / 模块 / `LumacApp` / 资源 bundle(`lumac_lumac.bundle`)都叫 lumac。
- 实时指标一律走原生 syscall,不用 `mo status`(它每次冷启动,速率/负载这类差值不可靠);`mo status` 只供健康评分、机型、电池、蓝牙、温度这些它专有的字段,**30 秒一次且只在主窗口可见(未关/未最小化/未被遮挡)或 HUD 打开时跑**,进程列表同样只在可见时刷;原生指标 1 秒一次、始终跑(菜单栏图标只用它)。原来 2 秒一次、全天候:`mo status` 是 bash 脚本,每次 fork ~300 个子进程、~1 秒 CPU,常驻占 ~35% 核,让 lumac 上了系统「使用大量能耗」,别改回去。
- 进程列表只显示「真正的应用」:有 .app bundle 且非后台代理(`ProcessLister.isListed` / `isSystemAgent`,按 Info.plist 的 `LSBackgroundOnly` / `/System` 下的 `LSUIElement` 判定),外加 `listedSystemProcesses` 白名单(目前仅 WindowServer)。名字用 `FileManager.displayName` 取本地化名(访达 / 备忘录 …)。
- 注释解释「为什么」,与现有高密度注释风格保持一致。

## 当前状态

- 概览仪表盘:健康 | 网络/CPU/GPU · 电池/内存/磁盘 的等高网格 + 按内存排序的应用列表;**mo 缺失时不再整页替换**——指标全是原生读的,只有健康评分/机型/电池/蓝牙/已运行来自 `mo status`,所以改成页顶一条 `CLIMissingBanner`,仪表盘照常显示;菜单栏显示内存占用%(白/琥珀/红随占用)+ 上下行网速。进程内存取 `phys_footprint`(`proc_pid_rusage`,与活动监视器一致、非虚高的 RSS;取不到的系统进程回退 RSS)。
- **窗口生命周期**:点窗口 X(关主窗)→ `AppDelegate` 监听 `NSWindow.willCloseNotification`(按 `identifier=="main"` 认主窗)→ `setActivationPolicy(.accessory)`,收成纯菜单栏挂件(无 Dock 图标),app 不退(`applicationShouldTerminateAfterLastWindowClosed=false`);菜单栏 HUD「打开 lumac」→ `app.openMainWindow()`(切回 `.regular` + `reopenWindow` 用 `openWindow(id:"main")` 重开);HUD「退出」→ `NSApp.terminate` 全退。`app.mainWindow` 弱引用 + `reopenWindow` 闭包在 RootView.onAppear 里挂。
- 深度清理(clean)走通:dry-run 扫描 → **类目可展开、逐条路径勾选**(`ScanItem.entries: [ScanEntry{path,bytes,selected}]`,类目框三态 全/部分/无)→ 移废纸篓;安装包并入 clean 页作不勾选行。`Trash.run(paths:)` 只删被勾选的路径。
- **废纸篓不作清理类目**:`CleanParser` 跳过 `"Trash"` 类目——「清理」就是移废纸篓,对已在废纸篓的文件再清理是循环(0 字节、还虚高「可释放」)。`CleanupModel.scan` 启动 clean 扫描前调 `MoleConfig.ensureTrashWhitelisted()`,把 `~/.Trash` 幂等写入 mo 白名单让 `mo clean` 扫描跳过废纸篓。改由独立「清空废纸篓」按钮处理。
- **清空废纸篓**:`EmptyTrashButton`(自包含组件,清理页 ReadyStage/DoneStage/EmptyStage 三处都放)——`.task` 里 `Trash.trashSize()` 算大小(挂在始终渲染的视图上,否则空视图丢任务)、非空才显示;点击 → 确认「永久删除」→ (开了 Touch ID 则)指纹 → `Trash.emptyTrash(progress:)` 逐项删、显示进度条 + 完成弹窗。**清的是 Finder 聚合的全部废纸篓根**(`Trash.trashRoots()`:`~/.Trash` + iCloud `~/Library/Mobile Documents/.Trash` + 外置卷 `/Volumes/*/.Trashes/<uid>`,跳过指向启动盘的软链),与访达「清倒废纸篓」一致(iCloud 那份是跨设备永久删除);`trashSize()` 跨根求和,故只有 iCloud 有内容时按钮也会显示。root 属主的残留 lumac 删不动(TCC 护 `~/.Trash` + 需 root,`osascript` 提权也过不了 TCC),弹窗改给「打开废纸篓」引导去访达手动清(Finder 有 entitlement)。
- 项目产物(purge):**没有独立页面,并进 深度清理 的列表**。结构上它跟 clean 就是同一个东西(同一个 `CleanupCommand`/`CleanupModel`/`CleanupView`/`Trash.run`,只是扫描结果一个读清单文件一个读 stdout);原来待的「软件」区讲的是装着的应用,单位对不上。
  - `CleanupModel.scan` 用 `async let` 让 clean(~32s)和 purge(~2.8s)重叠,总耗时不变(前提是 MoCLI 不占 actor,见下);purge 失败用 `try?` 吞掉,不能带崩整个扫描。
  - `PurgeParser.categories` 返回**两个 `ScanItem`**(项目构建产物 / 项目依赖包),项目目录是其中的 `ScanEntry`——和缓存类目同页时,散装十几行 `node_modules` 会把别的类目埋掉;类目可展开,逐条勾选照旧。
  - **按恢复代价分档**:`Cost` 按 basename 分「可再生」(target/dist/DerivedData/__pycache__…,`.safe` 默认勾选,排前)和「需联网重下」(node_modules/Pods/vendor/venv/.venv/.tox/.nox/.gradle/.terragrunt-cache,`.review` 默认**不**勾,排后)。mo 的 `MOLE_PURGE_TARGETS` 把两类混在一个列表里,这一层是 lumac 自己加的——「在高铁上删了 node_modules 就跑不了项目」是真实代价。
  - **越界路径不静默丢弃**:`isDeletable` 拒掉的(外置盘、`/opt`)进 `result.skipped`,ReadyStage 与 EmptyStage 都显示「N 项被跳过 · 悬停查看原因」。护栏本身没放宽(有意为之)。
- 卸载应用(uninstall):**列表纯原生,残留清单以 mo 为准**。分工依据是「数据 vs 知识」——有哪些 app、多大、上次用是什么时候是数据,原生秒出;**残留归属是知识**,mole 有 ~3100 行 `app_protection*.sh` + `bundle_resolver.sh`,里面是 issue #993(卸载 Claude.app 把 Claude Code 的 `~/.claude` 一起删了)这类只能踩出来的规则,按 bundleId + 显示名扫一遍复现不了。实测同一个 app 原生 6 项 / mo 9 项。
  - **流程**:`select(app)` 先跑 `AppScanner`(毫秒级)出草稿,同时后台跑 `mo uninstall --dry-run <bundle 文件名>`,解析成功就**整份替换**并标「已复核」;失败/超时/没装 mo 保留草稿并标红。`PreviewSource` 驱动这行状态。
  - **提前收工(重要)**:清单在 26.4s 打印完,进程要跑到 46.4s 才退——后 20s 是 dry-run 空转。`runUninstall` 流式读 stdout,`stopWhen` 命中 `Enter confirm` 就杀进程组返回。**真正的 `mo uninstall` 绝不能提前停**(该干的活都在确认之后),所以 `stopWhen` 只给预览用。
  - **取消要真杀进程**:`ProcessBox` + `withTaskCancellationHandler`。`task?.cancel()` 只取消 Swift Task,mo 会把全盘扫描跑完,快速点几个 app 就并发好几个。mo 是 bash 会派生子进程,先 `pkill -9 -P` 再 `SIGKILL`。另用 `generation` 世代号护住 `defer`——被取消的旧任务 defer 是异步跑的,可能在新任务启动后才执行。
  - **三道拒绝**(宁可回退也不能张冠李戴):`Matched N app(s)` 必须 N==1、必须找得到 `Files to be removed:` 块、结果里必须含用户选中的那个 bundle 路径。任一不满足返回 nil,回退草稿。
  - **复核没完成不能删**:`canExecute` 含 `!verifying`。mo 的清单会整份替换草稿,替换前动手就是在用 lumac 自己都认为更不可靠的那一份。
  - **草稿要尽量等于复核结果**:`AppScanner.userPrefixed` 覆盖 Containers / Group Containers / Application Scripts / Application Support / Caches / HTTPStorages / WebKit / Preferences / Preferences/ByHost / Saved Application State / Logs,全部走**边界匹配**——只对 `<dir>/<bid>` 精确查找会漏掉扩展了 bundleId 的兄弟目录(fuse-t 同时有 `…fskit-srv` 和 `…fskit-srv.module`)。CrashReporter 的文件按 app 名命名,单独按 `name + "_"` 前缀扫。
  - **预览页两段式 + 逐项勾选**:`LeftoverKind` 给每条一个中文类别,`LeftoverTier` 决定分段——`.auto` 默认勾选;`.confirm` 默认不勾(目前两类:**群组容器**同厂商可能共用、**按显示名匹配到的 Application Support**,后者正是「按名字匹配 vs 按归属判断」那个坑,卸载 Claude 时 243MB 的 `~/Library/Application Support/Claude` 落这里默认不勾,**有意为之**);`.locked` 显示锁图标而**不是**假勾选框(`!Trash.isDeletable` 的一律锁),每条带原因。分类只在 `UninstallLeftover.make` 里算一次,草稿和复核共用。执行只删 `selectedItems`。
  - **界面约定**:复核进度长在右下角主按钮上(`ProgressPrimaryButton`),不弹窗、不显示秒数(估算只对着一台机器测过),`MoScanPhase.label` 对 `.starting` 返回 nil(一闪而过又被替换的文字像卡顿);进度下限由 mo 的三个可观测标记设定(banner 0.2s / Matched 2.5s / Files 25.6s),中间 23s 静默靠 elapsed 填充,**封顶 0.92**,绝不跑到没观测到的地方;第二段只有锁定项时标题是「lumac 无法删除」不是「需要确认」;条目大小用 `Trash.directorySize` 本地量(mo 有些行根本没 size,且要和完成页口径一致)。
  - **厂商自带卸载程序**:`VendorUninstallerScanner` 扫 `/Library/Application Support/<name>`、`~/Library/Application Support/<name>`、`/usr/local/share/<name>`、`<app>/Contents/Resources` **各一层**(深扫会翻出内嵌依赖自带的卸载器),找名字含 uninstall 且可执行的。本机命中 3 个。值得单列是因为它比通用扫描既多又少:fuse-t 的 `uninstall.sh` 删 `/usr/local/{bin,include,lib}` 下四样任何 bundleId 扫描都找不到的东西,同时**故意不碰** `/Library/Frameworks/fuse_t.framework`(别的软件链接着)。**lumac 不执行它**——任意厂商代码,要紧的还要 root(读脚本头 `EUID`/`id -u` 判断),只展示 + 给「复制命令」和「在访达中显示」。
  - **root 属主的 app 本体走 mo 提权**(**唯一用到 mo 命令的卸载分支**):原生 `trashItem` 删不动 root 属主的 `.app`(TCC/App 管理授权都没用,卡的是 Unix 属主)。`execute()` 原生删完后 `isRootOwnedAppFailure` 成立就**自动接力** `uninstallViaMo()`,借 mo 自带的 Touch ID + 免密 sudoers(`/etc/sudoers.d/mole`)删除;RunningStage 期间 `elevating` 显示不确定进度条,不停在失败屏,只有 mo 也失败才落到手动屏(「用管理员权限删除」重试 + 「复制命令」`sudo mv … ~/.Trash/`)。名字用 bundle 文件名(非本地化显示名)匹配更稳。
  - **成功与否只看 app bundle 还在不在磁盘上**(`fileExists`),不看 mo 的措辞:`uninstall.sh` 直接名字分支结尾是裸 `return 0`,取消确认、拒绝管理员授权、真删掉都退 0(只有「没匹配到应用」退 1);`success_count == 0` 时标题**照样**印 "Uninstall complete",老的 `contains("Uninstall complete")` 判定会把「什么都没删」读成成功。`MoUninstallReport.parse` 只负责**解释失败原因**(Aborted. / Admin access denied / Uninstall incomplete + "Failed: …" / No applications were uninstalled. / dry run),字符串对着 mole 1.53.0 的 `batch.sh` 核过。喂 mo 的 `y\n\n\n` 实测过:第一道 `read -r confirm` 吃 `y`,第二道 `read -r -s -n1` 吃换行(空输入同样算确认)。
  - **历史只在 app 本体真删掉才记**:`appRemoved = outcome.trashed.contains(selected.path)`。之前条件是「有任何东西进废纸篓」,导致 root app 删失败(残留删成功)也误记一条卸载,列表里堆重复条目。
- 系统优化(optimize):`mo optimize --dry-run` 预览维护项 → `mo optimize` 执行(实测非交互、不弹 sudo、需权限的任务自动跳过,不会卡住)。`OptimizeParser` 解析 `➤ 类目 / ✓→◎ 动作` + 汇总行。不删个人文件,自有视图 OptimizeView(在 RootView 里 optimize 先于通用 cleanup 分流)。
- 启动时检查更新:`UpdateChecker` 每次启动(引导完成后)后台查一次 **mole CLI** 更新——`mo --version` 对比 GitHub `tw93/Mole` 最新 release tag(去 v/V 前缀,数值逐段比 semver),有新版弹 alert(可「用 Homebrew 更新」跑 `brew upgrade mole` 或终端 `mo update`)。**启动的自动检查仍只查 mole**;**手动「检查更新」**(品牌菜单 + 设置→关于,`AppState.checkNow` → `UpdateChecker.all()`)则**同时查 lumac 和 mole**,各报一行。lumac 比 `volcano-1025/lumac` 的 GitHub release——当前仓库无 release,故 `latestTag` 收到 404 报「暂无发布版本」(与网络失败区分开);发布带 tag 的 release(如 `v0.2`)后自动生效。lumac 不走 brew,其更新动作是开 `releases` 页手动下载。
  - **两处口径不同,必须对齐(`Update.brewReady`)**:检查更新查的是 **GitHub release**(上游一发就知道),更新页能装的是 **homebrew-core 的 formula**——mole 的 formula 标了 `autobump: false` / `bumped_by_upstream`,得等上游自己提 PR,实测 GitHub 发 V1.56.1 一小时后 homebrew-core 仍是 1.56.0。那段空窗期里弹窗喊「有新版」、更新页一条不列(**两边都没错**),而「用 Homebrew 更新」按下去 brew 装不到新版、退 0、弹窗照旧——跟上次的索引冻结 bug 长得一模一样,其实是另一回事。`moleOutcome` 现在多问一句 `Brew.formulaVersion("mole")`(`brew info --json=v2`,读的就是更新页那份索引,实测 0.5s),填进 `Update.brewReady`:false 时**手动检查**照常报「有新版本(Homebrew 还没收录,稍后再更新)」但**不给 Homebrew 按钮**(RootView 弹窗 / SettingsView 行尾各一处,`AppState.updateMole` 再兜一道),**启动的静默检查干脆不弹**(`UpdateChecker.mole()` 过滤)——没法行动的打扰正是 lumac 不做的那种提醒。没装 brew 时 `brewReady` 恒 true,文案不变(那条路是 `mo update`)。
- 应用更新(updates):**无 mo 命令**。本机只有 `brew`(无 `mas`/Sparkle),故只覆盖 Homebrew。`Brew.outdated` 解析 `brew outdated --json=v2`(cask=应用在前,formula=命令行在后),`brew upgrade [--cask] <name>` 更新。无 TTY 时 sudo 会即时失败而非卡住,所以从 GUI 跑是安全的。页面明说「只覆盖 Homebrew 管理的应用」。
  - **镜像 + 超时(重要,别去掉)**:GUI 应用不继承用户 shell,brew 默认走官方 `formulae.brew.sh`——国内网络下 16MB API 索引下不完会**永久卡住**(实测 20s 只下 663KB),而 `Brew.run` 原本对进程无超时 → 更新页无限转圈。`Brew.run` 现在:①注入 `HOMEBREW_API_DOMAIN`/`HOMEBREW_BOTTLE_DOMAIN` 清华镜像(仅当用户未自设时,如 `launchctl setenv`);②注入 `HOMEBREW_CURLRC` 指向 `~/Library/Application Support/lumac/brew.curlrc`(`speed-limit 1024 / speed-time 30`):brew 的 curl 有 `--retry`+`--continue-at` 却没有低速中止,经 Egern 这类 TUN 代理时连接会**静默卡死**(ESTABLISHED、15 分钟 0 字节,同时新开请求 6 秒下完),加了它 curl 30 秒后断开、自己重试续传;③给进程设超时(outdated 180s / upgrade 1800s),超时先 `pkill -P` 杀 curl 子进程再 `SIGKILL` brew(解开管道阻塞),抛 `CLIError.timedOut`。终端里的 brew 是另一回事,要快需用户自己在 `~/.zshrc` 配镜像。
  - **索引必须刷新(`RefreshIndex`)**:`brew outdated` 只跟**本地缓存的 formula 索引**比,从不查网。原来每条命令都带 `HOMEBREW_NO_AUTO_UPDATE=1`(为了省掉每次调用前的 auto-update),索引就冻在「用户上次在终端跑 brew」那一刻——实测 mole 1.55.0 已发布、本机装的是 1.54.0,更新页却只列另外 7 个,因为**对这个 brew 而言 1.54.0 就是最新**(缓存索引里 `"mole":…"stable_version":"1.54.0"`);而品牌菜单的「检查更新」查的是 GitHub release,所以两处对不上。改成 `RefreshIndex` 三档:`.off`(即旧的 `NO_AUTO_UPDATE`,**upgrade 用**——照列表那份快照装,免得行里写 A 装成 B)、`.hourly`(`HOMEBREW_AUTO_UPDATE_SECS=3600`,自动加载用,反复开页不重下索引)、`.force`(`=1`,**刷新按钮**用,按了就该真去查)。auto-update 会重下 `~/Library/Caches/Homebrew/api/internal/packages.<平台>.jws.json`,冷启 ~15MB(故 outdated 超时提到 180s),索引没变时 304、实测 ~5s。
- 磁盘分析(`mo analyze -json`):面包屑下钻 + 按目录/大文件切换 + 访达显示 + 单文件移废纸篓(带确认)。**概览根(无路径)mo 只返回目录汇总 + insight,条目 `is_dir` 全 true、没有单个文件**,故「大文件」在根层必空——空状态按 `model.atRoot` 提示「进入某目录后可看大文件」,**非 bug**;下钻进某路径后 `mo analyze <path>` 才列出文件级条目。
- **撤销(操作记录)**:`Trash.Move{from,to}` 记下每一项被移到废纸篓的**哪个位置**——`trashItem` 的 `resultingItemURL` 原来是丢掉的,而废纸篓遇到重名会改名,只有原路径找不回去,所以这之前根本没法撤销。`HistoryRecord.moves` 可选(老记录和不产生移动的操作解码成 nil),`canUndo` = 有 moves 且没撤销过。`Trash.restore` 的规则:废纸篓里没了 → 报「可能已清空」;原位置已有同名文件 → **拒绝,不覆盖**;父目录被清理端走了 → 自动重建。撤销成功才写 `undoneAt`(一件都没还原就标已撤销等于谎报)。**系统优化没有 moves**(不删文件),**mo 提权删除的那部分也没有**(mo 自己扔的,不告诉 lumac 去向),所以卸载 root app 的记录只能还原用户空间那几项。撤销不加确认弹窗——不覆盖任何东西,不是破坏性操作。
- 操作记录:**不用 `mo history`**——mo 的历史会把 `--dry-run` 预览(打开扫描页就会触发)记进去、还带误导性的「would free」体积,且 lumac 真正的删除是自己移废纸篓、根本不经过 mo。改为 `HistoryStore` 自记账,存 `~/Library/Application Support/lumac/history.json`,只在真正执行(clean/purge/uninstall/optimize)后记一条真实释放量。老数据不迁移,新装从空开始。
- 设置:**居中弹窗 sheet**(不是内容页;品牌菜单点「设置」开 `app.showingSettings`,固定 600×680 带标题栏+完成),内含 主题、危险操作确认、底部状态条(均真实生效)+ 扫描与白名单(直接读写 `~/.config/mole/{purge_paths,whitelist}`,`# 头注释 + 空行 + 每行一路径`,NSOpenPanel 选目录、`~` 化)+ 权限与安全(完全磁盘访问状态/去开启、Touch ID 确认开关、重看引导)+ 关于(mo 检测 + 版本号徽章/废纸篓/检查更新——**行内**查 lumac+mole,因 alert 盖不住设置 sheet)。mo 的 `--paths`/`--whitelist` 是交互 TUI(非 TTY 会卡住),故绕开直接写文件。
- **权限与引导(阶段 3)**:首启 `OnboardingView`(欢迎→完全磁盘访问→Touch ID/完成),`didOnboard` 存 UserDefaults;`FullDiskAccess.granted` 用能否读 `~/Library/Application Support/com.apple.TCC` 判断(慢轮询刷新 `app.fdaGranted`),未授权时 RootView 顶部常驻红色横幅;Touch ID 走 `LocalAuthentication` 的 `.deviceOwnerAuthentication`(`requireBiometric` 开时,清理/卸载执行前 `app.confirmBiometric` 拦一道,失败/取消不执行;设备不支持则放行)。
- **删除的语义护栏 `Protected`(重要)**:`Trash.isDeletable` 原本只判**路径形状**(≥3 段、允许前缀),这在「路径全部来自 mo」时够用——mo 自己有 ~3000 行保护规则,根本不会列出危险路径。但 lumac 有三条**绕开 mo 的删除入口**:磁盘分析的悬停垃圾桶(用户能直接下钻到 `~/.claude/projects` 点删除)、`InstallerScanner`、`AppScanner`。实测老的 `isDeletable` 对 `~/.claude/projects`、`~/.codex/sessions`、`~/.ollama/models`、`~/.cache/huggingface`、`~/Pictures/*.photoslibrary`、`com.apple.e5rt.e5bundlecache` **全部放行**。`Protected.covers()` 补上这一层:AI 会话记录(不可替代)、模型权重(Ollama 按哈希分块共享,外部删会弄坏别的模型)、个人资料库、`com.apple.e5rt.e5bundlecache`(名字带 cache 其实是神经引擎编译好的模型)。**同时拦「祖先」**——删 `~/.claude` 会连 `projects` 一起带走,所以祖先目录也拒绝。这份名单刻意很短:不是重造 mole 的知识,是补 lumac 自己开的口子。
- **字节单位一律十进制(1 MB = 10^6)**:`Size.format` 与 `Size.firstByteValue` 都用 10^9/10^6/10^3。理由是这个 app 周围的所有人都用十进制——Finder 从 10.6 起、mole 的 `bytes_to_human`(`lib/core/base.sh:749`)也是。原来两个方向都用 2^30:显示上把 1.8 MB 写成 1.7 MB,更要命的是**解析** mo 写的 `1.65GB` 时乘 2^30,虚高 7.4%,而这个数就是清理页顶上的「可释放 X」。另外 MB 现在保留一位小数(原来取整,1.71 MB 显示成「2 MB」)。
- **Trash 安全护栏**:`Trash.isDeletable` 原本要求路径 ≥3 段(挡住 `/Applications` 等根),为卸载放开了唯一例外——**顶层 `/Applications/*.app`**(正好 2 段,`.app` 结尾);`/Applications` 目录本身仍被 `forbiddenRoots` 挡住,嵌套路径仍走 ≥3 段规则。改这里要非常小心。`Trash.directorySize` 枚举**不再跳过隐藏文件**(缓存/容器/app bundle 里全是点文件,跳过会把「可释放」和实际释放量都算少)。
- **子进程不占并发线程池(别改回去)**:`MoCLI.run` / `MoCLI.uninstallApp` / `Brew.run` 的 spawn+drain+wait 是同步阻塞的,整段包在 `DispatchQueue.global(qos:.userInitiated).async` 里再 resume continuation。原本直接跑在 continuation 体内:MoCLI 是 actor,一次 `mo clean --dry-run`(几十秒)会把 actor 和一条协作线程池线程占满,2 秒一次的 `mo status` 轮询全部排队;`brew upgrade` 更是能占满 1800 秒。
- **取消清理要报实际结果**:`CleanupModel.execute` 拿到 `Trash.run` 的返回值后**不再** `guard !Task.isCancelled`——`Trash.run` 自己在循环里检查取消并返回已完成的部分,丢掉它会让「取消」后的完成页显示「0 个位置 · —」,而文件其实已经进了废纸篓。
- **设置每次打开都重读配置**:`SettingsView.task` 调 `configModel.reload()` 而非 `loadIfNeeded()`——`ensureTrashWhitelisted()` 和 mo 自己都会在背后改 `~/.config/mole/{purge_paths,whitelist}`,用一次性加载的内存副本回写会把它们的改动覆盖掉。
- **未完成**:首启第三步「自动清理频率」未做。
- **有意不做:通知提醒**。不是技术限制,是产品决定——mole 作者的原话是「装了之后它不会隔三差五弹个通知提醒你该清理了,也不会扫完之后跳出来说你的电脑有多危险。你想清的时候打开它,不想的时候它就跟不存在一样」。lumac 跟这个定位一致,别再把它当 TODO 捡起来。
- **能力边界(设计使然,非缺陷)**:`installer` 交互 TUI 无清单文件 → 已在 clean 内用原生 `InstallerScanner` 覆盖,无独立页;更新只覆盖 Homebrew(无 `mas`/Sparkle);`purge` 同样没有独立页,并进 clean(见上)。
- **已移除:启动项页**。原来是 `LoginScanner`(纯原生读 launchd plist + `launchctl print-disabled`,只有用户级 agent 能切)。删掉是产品决定不是技术问题:它只覆盖 launchd agent/daemon,拿不到 BTM「打开时登录」项(要 `sfltool`/提权),而系统设置里那一页是完整的——给一份看着像全集、实际有缺口的开关清单,比不给更糟。要找回来:`git show e52c287:Sources/lumac/CLI/LoginScanner.swift`(连同 LoginModel/LoginView;用固定 commit 而不是 HEAD,因为删除已经提交)。
- **提权边界(重要,别再误判)**:自签名做不了**常驻**特权 helper(SMJobBless 需 Developer ID),但**一次性提权删除做得到**——lumac 不自装 sudoers,而是把 root app 本体的删除**甩给 mo**(mo 已有免密 sudoers + Touch ID)。所以:root 属主的 `/Applications/*.app` **能删**(走 mo);`/Library` 系统项(LaunchDaemons/PrivilegedHelperTools)仍 `reviewOnly` 只展示不删(不是 app 本体、不进 mo uninstall 的对象);清空废纸篓里的 root 残留 **lumac 删不了**(TCC 护 `~/.Trash`,root 也绕不过,`osascript` 提权同样过不了 TCC),引导去 Finder。设置里的 Touch ID 开关(`requireBiometric`)是 lumac 自己的**操作确认门**,与 mo 的提权是两回事。
- 所有主要页面均已实现,无 `尚未实现` 占位(PlaceholderView 仅作兜底)。
- 已上 git,远程 `git@github.com:volcano-1025/lumac`(main 分支);删除不可逆,谨慎。
