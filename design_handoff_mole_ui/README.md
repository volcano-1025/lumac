# Handoff: Mole UI（Mole CLI 的 macOS 图形界面）

> **归档：这是 2026-08 实现之前的原始设计交付文档，保留作视觉与交互基线，不描述当前行为。**
> 与现状已知的出入：实际的删除由 lumac 自己执行（`FileManager.trashItem`），mo 只负责扫描和 root 应用提权；
> 「启动项」页已移除；「项目产物」已并入深度清理。当前实现以仓库根目录的 README.md 和 CLAUDE.md 为准。

## Overview
Mole 是一个 macOS 命令行清理工具（`mo`，https://github.com/tw93/Mole），提供 clean / uninstall / purge / installer / optimize / analyze / status 等能力。本设计把它包装成一个 macOS 应用：图形界面负责扫描结果的呈现、勾选与确认，**实际操作仍然由 mole CLI 执行**。界面对用户完全隐藏命令行——不出现命令字符串、不出现终端输出。

## About the Design Files
本包内的 HTML 文件是**设计参考**（用 HTML 做的高保真原型），不是可直接上线的代码。目标是在真实工程环境里**重建**这些界面：
- 推荐 SwiftUI（原生体验最佳，Liquid Glass 材质、菜单栏挂件、Touch ID 都有系统 API），
- 或 Tauri（前端 + Rust 壳，可直接 spawn `mo` 子进程，开发更快）。

原型里的数据全部是假数据与模拟耗时，真实实现应解析 `mo` 的输出（优先使用 JSON 输出模式，其次解析文本）。

## Fidelity
**High-fidelity。** 颜色、字号、间距、圆角、材质、状态变化都已定稿，应按本文件的数值 1:1 还原（在目标平台的等效控件上）。

## Design system 基线
本设计遵循 Apple HIG 与 Liquid Glass 采用指南：
- **两层结构**：导航层（工具栏、侧栏、菜单栏 HUD、通知）使用半透明玻璃材质；内容层不透明（略带透明以承接壁纸色），二者层次清晰分离。
- **同心圆角**：窗口 19 → 弹窗/浮层 18 → 卡片 14 → 列表 13 → 侧栏项 9。
- **分组标题不使用全大写/加宽字距**（HIG 已弃用），用常规标题样式。
- **列表行高与内边距放宽**，描边统一 0.5px 发丝线。
- **图标统一一套线性图标**（24×24 viewBox，stroke 1.7，round cap/join，currentColor）；不混用字符符号。SwiftUI 实现时应换成对应的 SF Symbols（见下方映射）。
- **工具栏按功能分组**，同组共享一个胶囊背景；用图标 + tooltip，不与文字混排。

## Design Tokens

### 颜色（浅色 / 深色）
| Token | Light | Dark | 用途 |
|---|---|---|---|
| `--bg` | `#fbfbfc` | `#1c1e21` | 卡片、弹窗底 |
| `--content` | `rgba(251,251,252,.8)` | `rgba(28,30,33,.8)`* | 内容区（半透明，透出壁纸） |
| `--panel` | `#eceef1` | `#17191c` | 次级面板、空状态图标底 |
| `--hover` | `#f2f4f6` | `#24272b` | 行 hover |
| `--fg` | `#1b1d21` | `#e8eaee` | 主文字 |
| `--fg-rgb` | `27,29,33` | `232,234,238` | 透明度派生用 |
| `--sel-bg` | `#4a5763` | `#7d8b99` | 选中态、主按钮 |
| `--sel-fg` | `#ffffff` | `#16181b` | 选中态文字 |
| `--accent-text` | `#3c4855` | `#a8b6c4` | 强调色文字（对比度 ≥4.5:1） |
| `--accent-soft` | `rgba(74,87,99,.1)` | `rgba(125,139,153,.18)` | 强调色浅填充 |
| 危险色 | `#a8412c` | 同 | 删除、低电量、高风险标签 |

\* 深色实际值为 `rgba(35,38,42,.42)` 系的玻璃 + `--content`，以源文件为准。

### 玻璃材质
| Token | Light | Dark |
|---|---|---|
| `--glass` | `rgba(246,247,249,.44)` | `rgba(35,38,42,.42)` |
| `--glass-hi` | `rgba(255,255,255,.9)` | `rgba(255,255,255,.22)` |
| `--glass-line` | `rgba(27,29,33,.09)` | `rgba(232,234,238,.1)` |
| `--glass-sheen` | 顶部→透明→底部微亮的线性渐变 | 同结构、更低透明度 |

滤镜：`backdrop-filter: blur(44px) saturate(200%) brightness(1.06)`；边缘 `inset 0 .8px 0 var(--glass-hi)` + 底部 `inset 0 -6px 14px -10px`。
SwiftUI 对应：`.glassEffect()` / `NSGlassEffectView`，**不要**自己画模糊——让系统处理。

### 字体
- 界面：系统字体栈（`-apple-system` / SF Pro / PingFang SC）
- 数字与体积：等宽（原型用 JetBrains Mono，原生实现请用 **SF Mono**）
- 字号：页面标题 19–21 / 卡片标题 13–14 / 正文 12–13 / 辅助 11–11.5 / 徽标 10–10.5
- 低对比文字最低 `alpha .58`（玻璃与半透明内容层上的可读性下限）

### 尺寸
窗口 1180×772；工具栏高 52；侧栏宽 232；侧栏项高 34；列表行内边距 15px 14px；内容区内边距 26px。

### 圆角与阴影
圆角：19 / 18 / 15（胶囊）/ 14 / 13 / 9。
窗口阴影：`0 32px 80px rgba(fg,.28), 0 2px 6px`；浮层：`0 20px 46px`；通知：`0 12px 34px`。

## Screens / Views

### 1. 概览（status）
`mo status`。左上健康评分卡（250px 宽，环形/条形 + 评分 + 机器信息），右侧 2×2 指标卡（CPU / GPU / 内存 / 磁盘，标签 + 数值 + 进度条 + 副标）；下方左右两张卡：**网络**（柱状实时图 31px 高 + ↓↑ 速率 + 今日流量统计一行，分隔线与右卡对齐）与**电池**（大号电量 + 供电状态 + 循环/健康度，右侧 4 个 38px 环形显示 MacBook / AirPods / 充电盒 / 鼠标电量，低电量用危险色，右上角温度标签）；底部**占用最高的进程**表铺满剩余高度：名称 + CPU（迷你条形 + 数值）+ 能耗 + 内存 + ✕ 结束进程，表头可按 CPU/能耗/内存排序（当前列显示 ▼），共 24 条可滚动，滚动条隐藏。

### 2. 清理类页面（clean / uninstall / purge / installer / optimize）
四阶段状态机：**空闲**（说明这次会做什么，主按钮开始检查）→ **扫描中**（进度条 + 当前扫描路径）→ **待确认列表**（全选/全不选、可释放合计、逐行勾选：名称 + 风险标签 + 路径 + 占比条 + 体积；勾选行左侧有一条强调色标记条）→ **执行中**（进度条 + 步骤逐项打勾）→ **完成**（释放体积大字 + 后续操作）。
底部状态条只在需要时出现，用大白话说明后果（例：「已选 6 项 · 105.6 GB · 将移入废纸篓，可随时还原」）。危险操作走确认弹窗（`requireConfirm` 可关）。

### 3. 应用更新（updates）
检测本机应用的可用更新：应用图标 + 名称 + 来源标签（App Store / Homebrew / Sparkle / Electron）+ 版本 `旧 → 新`，行内「忽略更新」与「更新」按钮，右上角「全部更新」；更新中显示行内进度条。

### 4. 磁盘分析（analyze）
`mo analyze`。分段控件切换「按目录 / 大文件」，列表：序号 + 文件夹/文档图标 + 名称 + 标签 + 占比 + 体积，点击可下钻；底部注明删除等于移入废纸篓。

### 5. 操作记录（history）
每条：时间 + 操作类型 + 释放体积 + 「还原」入口。

### 6. 设置（settings）
分组列表：清理白名单 / 优化白名单（`--whitelist`）、项目扫描路径（`purge --paths`）、删除方式（废纸篓 / 直接删除）、Touch ID、通知提醒、外观（跟随系统 / 浅色 / 深色，默认跟随系统）、测试版更新通道、自动清理频率、原型演示入口。

### 7. 菜单栏挂件（常驻）
菜单栏图标为鼹鼠剪影 + 上下行网速；鼹鼠奔跑速度随内存占用变化（48% ≈ 0.95s/循环，71% ≈ 0.68s）。点开是玻璃 HUD 面板（296px）：健康分、CPU/内存/磁盘指标、占用最高的 12 个进程。

### 8. 首次启动引导与异常态
三步引导：介绍 → 权限申请（完全磁盘访问必需、Touch ID 可选）→ 自动清理频率（每周/每月/关闭 + 仅接电源时执行）。
异常态：权限不足（说明缺什么、少扫到什么、去哪开、可跳过）、扫描失败（列出被占用而跳过的目录，可重试）、空态（没什么可清理）。

## 图标映射（原型线性图标 → SF Symbols 建议）
概览 `gauge.medium`；深度清理 `trash`；卸载应用 `square.grid.2x2` + minus；项目产物 `folder.badge.gearshape`；安装包 `arrow.down.doc`；系统优化 `slider.horizontal.3`；应用更新 `arrow.down.circle`；磁盘分析 `chart.pie`；操作记录 `clock.arrow.circlepath`；设置 `gearshape`；文件夹/文档 `folder` / `doc`。

## Interactions & Behavior
- 所有破坏性操作先跑 `--dry-run` 扫描，用户勾选后才执行；默认移入废纸篓（可还原）。
- 进度与步骤状态来自 CLI 的流式输出；执行中可取消（发送中断信号，已完成部分不回滚）。
- 动效：浮层/弹窗 `moleRise`（6px 上移 + 淡入，0.18–0.35s ease）；进度条宽度过渡 0.3–0.8s；玻璃层变化交给系统。
- 外观切换、通知开关等偏好实时生效。
- 通知中心提醒：磁盘不足、自动清理完成、配件低电量。

## State Management
视图（当前页）、每页阶段（idle/scanning/ready/running/done/denied/failed）、扫描结果与勾选集、进度与当前步骤、排序列、主题模式（auto/light/dark）+ 系统深色标志、引导步骤与权限授权状态、设置项、通知队列、菜单栏 HUD 开关、实时指标轮询（2s）。

## CLI 映射
| 界面 | 命令 |
|---|---|
| 概览 / HUD | `mo status`（轮询） |
| 深度清理 | `mo clean --dry-run` → `mo clean` |
| 卸载应用 | `mo uninstall` |
| 项目产物 | `mo purge --paths <…>` |
| 安装包 | `mo installer` |
| 系统优化 | `mo optimize --whitelist <…>` |
| 磁盘分析 | `mo analyze` |
| 操作记录 / 还原 | 本地记录 + 废纸篓还原 |

真实实现注意：需要完全磁盘访问权限；部分操作需提权（优先 Touch ID / Authorization Services，不要在界面里暴露 sudo 提示）。

## Assets
- `assets/mole.png` — 鼹鼠剪影（用户提供，已去底裁边）。浅底上需反相为深色。图标层次与遮罩交给系统（Icon Composer）。
- 其余图标均为内联 SVG 路径，见源文件 `ICONS` 常量。

## Files
- `Mole App.dc.html` — 全部界面与交互（单文件原型，浏览器直接打开）
- `support.js` — 原型运行时（仅原型需要，不要移植）
- `assets/mole.png`

## Tweakable props（原型内）
`showSummaryBar`（底部状态条）、`requireConfirm`（危险操作确认）、`accent`（强调色，默认 `#4a5763`）。
