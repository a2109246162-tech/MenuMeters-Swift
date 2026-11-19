# MenuMeters Lite

> **MenuMeters Lite** —— 比原版更轻的 macOS 菜单栏资源监控 —— 为老 Mac 而生的原生 Swift 重写版。
> 单文件源码、零第三方依赖，实时显示 **CPU / GPU / 内存** 占用率。
> 实测：安装包 ~250 KB · 常驻内存 ~16 MB · 稳态 CPU < 1%。

```
菜单栏预览（圆点颜色可逐项自定义）：
  ● C  16%    ● G   8%    ● M  61%
```

## 与原版 MenuMeters / iStat Menus 的差异

本项目不是原版的移植，而是**面向老 Intel Mac 的极简重写**。核心差异：

| 维度 | 原版 MenuMeters（Obj-C） | iStat Menus | **本项目** |
|------|--------------------------|-------------|-----------|
| 技术栈 | Objective-C，多年未更新 | 商业闭源 | 单文件 Swift 5，纯官方框架 |
| 体积 | 数 MB（含偏好面板/多模块） | 数十 MB | **App ~380 KB / DMG ~250 KB** |
| 常驻内存 | 数十 MB | 上百 MB | **~16 MB** |
| 稳态 CPU | 视模块数量而定 | 较高 | **< 1%**（实测 0.7%） |
| 监控范围 | CPU/内存/磁盘/网络/时钟… | 全家桶 | **只保留 CPU/GPU/内存三核心** |
| 设置方式 | 独立偏好设置窗口 | 独立偏好设置窗口 | **菜单栏菜单即设置，无额外窗口进程** |
| 逐项配色 | 全局统一样式 | 主题式 | **点击任一项 → 圆点颜色子菜单（8 预设 / 系统取色器）** |
| 老 Mac 友好 | 新系统兼容性差 | 要求较新系统 | **macOS 12+，Intel 核显 GPU 直读，无需 sudo** |
| 价格 | 免费 | 付费 | 免费 + MIT 开源 |

**设计取舍**：砍掉磁盘/网络/电池等低频模块与独立偏好面板，把"监控三核心 + 个性化配色"做到极小极稳——监控软件自己不该成为老 Mac 的负担。

## 功能特性

### 设置与逐项配色

- **点击**任一菜单栏指标（左键或右键均可）→ 下拉菜单，其中「圆点颜色」子菜单：
  - 8 种预设色（天青/紫罗兰/翠绿/暖橙/朱红/明黄/樱粉/湖蓝），菜单内彩色圆点所见即所得，当前色打勾
  - **自定义颜色…** 调起系统取色器，实时生效
  - 恢复默认颜色 / 隐藏此项
- 菜单里的「设置」子菜单：
  - 刷新间隔：1 / 1.5 / 3 / 5 秒（老 Mac 可选 5 秒进一步省电）
  - 显示项目：逐项开关（至少保留一项）
  - 恢复所有默认颜色
- 所有设置经 UserDefaults **持久化**，重启不丢失

### 基础能力

- 菜单栏实时显示 CPU / GPU / 内存占用率（指数平滑，数值不跳动）
- 左键弹出详情菜单（含内存已用 / 总量 GB）
- 菜单内一键开启 / 关闭**开机自启**（用户级 LaunchAgent）
- 单实例保护；纯菜单栏应用，无 Dock 图标
- 自动适配浅色 / 深色菜单栏
- `--print-once` 调试模式，便于验证采样准确性

## 平台支持与限制

| 指标 | 实现方式 | Intel Mac | Apple Silicon |
|------|----------|-----------|---------------|
| CPU | Mach `host_processor_info` 差分采样 | ✅ | ✅ |
| 内存 | Mach `host_statistics64` | ✅ | ✅ |
| GPU | IOKit `IOAccelerator` 性能统计 | ✅ | ⚠️ 通常读到 0 |

> **GPU 限制**：`IOAccelerator` 的利用率字段仅在 Intel 核显驱动上暴露。Apple Silicon（M1/M2/M3/M4）不提供该字段，GPU 项显示 0；如需支持需改用 `powermetrics`（需 root），欢迎 PR。
>
> 这正是"为老 Mac 设计"的体现：在老 Intel 机器上无需任何权限即可直读 GPU，而多数现代监控工具反而放弃了这条路。

- 最低系统：**macOS 12.0 (Monterey)**；已在 macOS 12.7.6 + Intel Xeon / HD Graphics P530 验证
- 仅需 Command Line Tools 即可从源码构建，无需完整 Xcode

## 轻量化实测数据

在本机（2016 款 Intel Xeon / 16GB / macOS 12.7.6）实测：

```
$ ps -o %cpu,rss -p $(pgrep -f MenuMeters)
%CPU   RSS
 0.7  16184      # RSS 单位 KB ≈ 15.8 MB
```

- 采样全部走内核态 API（Mach / IOKit），**不 spawn 任何外部进程**
- 定时器带 20% 容差，允许系统合并唤醒、降低功耗
- 无网络请求、无后台服务、无独立偏好面板进程

## 安装

### 方式一：下载安装包（推荐）

前往 [Releases](../../releases) 下载 `MenuMeters.dmg`，双击挂载后把 App 拖入「应用程序」。

> 本项目为 **ad-hoc 签名、未经 Apple 公证**。首次打开若提示"来自身份不明的开发者"：
> `系统设置 → 隐私与安全性` → 点「仍要打开」；或终端执行 `xattr -cr /Applications/MenuMeters.app`。
> 彻底消除提示需 Apple Developer Program（$99/年）正式签名公证，对这类小工具通常没必要。

### 方式二：从源码构建

```bash
xcode-select --install   # 若尚未安装 Command Line Tools
git clone https://github.com/a2109246162-tech/MenuMeters-Swift.git
cd MenuMeters-Swift
swift scripts/make_icon.swift
iconutil -c icns output/MenuMeters.iconset -o output/MenuMeters.icns
bash scripts/build.sh
```

产物位于 `output/MenuMeters.app`。脚本使用相对路径，clone 到任意目录均可构建。

## 用法

- **查看数值**：菜单栏右上角 `C / G / M` 三个百分比
- **改颜色**：点击该项 →「圆点颜色」→ 选预设色或「自定义颜色…」
- **调间隔/显隐**：左键 → 设置 → 刷新间隔 / 显示项目
- **开机自启**：左键 → 「开启开机自启」
- **验证采样**：`MenuMeters.app/Contents/MacOS/MenuMeters --print-once`

## 卸载

1. 左键 →「开机自启已开启（点击关闭）」（如开过）
2. 左键 →「退出 MenuMeters」
3. 删除 `/Applications/MenuMeters.app`
4. 删除 `~/Library/LaunchAgents/com.stackmaster.menumeters.plist`（如存在）
5. 可选：`defaults delete com.stackmaster.menumeters` 清除设置

## 技术实现

| 模块 | 关键 API |
|------|----------|
| CPU | `host_processor_info(HOST_CPU_LOAD_INFO)` 两次采样差分 |
| GPU | IOKit `IOServiceMatching("IOAccelerator")` → `PerformanceStatistics["Device Utilization %"]` |
| 内存 | `host_statistics64(HOST_VM_INFO64)`，`(wired + active + compressed) / physical` |
| 菜单栏 | `NSStatusBar` / `NSStatusItem`，富文本 `attributedTitle` |
| 左右键区分 | `NSMenuDelegate.menuNeedsUpdate` + `NSApp.currentEvent` 类型判断 |
| 配色持久化 | `UserDefaults` + `NSKeyedArchiver`（secure coding） |
| 自定义取色 | `NSColorPanel` + `colorDidChangeNotification` |
| 自启 | 用户级 LaunchAgent，`launchctl bootstrap`（`open -a` 拉起） |

源码结构（核心逻辑单文件）：

```
.
├── src/
│   ├── main.swift        # 设置层 + 采样器 + 菜单栏 + 自启（全部逻辑）
│   └── Info.plist
├── scripts/
│   ├── make_icon.swift   # 生成 .icns 图标
│   └── build.sh          # 一键编译打包
└── output/               # 构建产物（gitignore）
```

## 验证与测试

```bash
top -l 2 | grep "CPU usage"                          # CPU 对照
ioreg -r -c IOAccelerator -l | grep "Device Utilization %"   # GPU 对照
vm_stat                                              # 内存对照
```

实测内存读数与 `vm_stat` 手算误差 < 0.1%。

## 更新日志

### v1.2.0
- 修复菜单无法弹出：改用原生 NSMenu 挂载，颜色设置直接放进一级菜单
- 产品更名为 MenuMeters Lite
- 新增右键/左键统一菜单与自检

### v1.1.0
- 新增右键逐项设置菜单：8 预设色 + 系统取色器自定义 + 恢复默认 + 隐藏此项
- 左键「设置」子菜单：刷新间隔（1/1.5/3/5s）、显示项目开关、恢复所有默认颜色
- 设置 UserDefaults 持久化；颜色面板观察者生命周期管理
- README 增加与原版对比、老 Mac 友好说明与实测数据

### v1.0.0
- 首个版本：CPU/GPU/内存菜单栏监控、开机自启、单实例保护、DMG 打包

## License

[MIT](LICENSE) — 自由使用、修改、分发，欢迎 Star 和 PR。

## 致谢

灵感来自经典工具 MenuMeters，用原生 Swift 面向老 Mac 重新实现，向原作者致敬。
