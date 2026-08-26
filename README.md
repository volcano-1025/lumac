# lumac

一个 macOS 菜单栏系统监控 + 清理工具。图形前端，底层的清理/扫描能力调用
[mole](https://github.com/tw93/Mole)（`mo`）命令行工具，CPU / 内存 / 磁盘 / 网络等实时指标
由 app 原生读取（mach / IOKit / getifaddrs），不依赖 CLI。

> 所有删除都会移入**废纸篓**（可随时还原），不做不可逆删除。

## 功能

- **概览** — 健康评分、CPU / GPU / 内存 / 磁盘、网络实时图、电池与配件、占用最高的进程。
- **深度清理** — 扫描缓存、日志、浏览器残留、安装包与已卸载应用的遗留；**类目可展开、逐条路径勾选**。
- **卸载应用** — 原生枚举 `/Applications`，连同偏好设置、缓存等用户空间残留一并移除；可按大小 / 最近使用 / 名称排序。
- **系统优化** — 重建缓存、刷新服务与索引（不删个人文件）。
- **启动项** — 查看并开关 launchd 用户级 agent。
- **应用更新** — 检查 Homebrew 管理的应用/命令行的可用更新。
- **项目产物** — 清理 `node_modules` / `dist` 等构建产物（可在设置里自定义扫描目录）。
- **磁盘分析** — 按目录/大文件下钻，看看空间都去哪了。
- **操作记录 / 设置** — 记录每次清理释放的空间；主题、Touch ID 确认、扫描白名单等。
- **菜单栏挂件** — 常驻显示内存占用与上下行网速；关闭主窗口后收成纯菜单栏后台运行。

## 环境要求

- macOS 26（Tahoe）及以上。
- 清理 / 优化 / 项目产物 / 磁盘分析需要 [`mo`](https://github.com/tw93/Mole) 在 `PATH` 上（`brew install mole`）；
  缺失时概览等页面仍可用，但会提示安装。
- 应用更新依赖 [Homebrew](https://brew.sh)。

## 构建

无需 Xcode——用 SwiftPM 编译二进制，`build.sh` 手工组装 `.app` bundle：

```bash
./build.sh            # debug；release 用 ./build.sh release
open build/lumac.app
```

## 签名与授权

`build.sh` 会优先用一个稳定的**自签名**身份 `lumac-selfsign` 签名（钥匙串里没有则回退 ad-hoc）。
用稳定身份的原因：macOS 的完全磁盘访问等 TCC 授权绑定签名的指定要求，稳定身份下授权可**跨重编译保留**。

首次创建签名身份：

```bash
./scripts/make-signing-cert.sh
```

自签名不被 Gatekeeper 信任，所以**下载后首次打开**需绕过一次（右键 → 打开，或
`xattr -dr com.apple.quarantine /path/to/lumac.app`）；之后更新会保留已授予的权限。

## 致谢

实际的清理/优化/分析由 [tw93/Mole](https://github.com/tw93/Mole) 完成，lumac 只负责把它包装成原生图形界面。
