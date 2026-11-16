# MenuMeters

> 一款轻量、现代的 macOS 菜单栏系统资源监控工具。
> 用原生 Swift 编写，实时显示 **CPU / GPU / 内存** 占用率，体积不足 400 KB，常驻内存约 15 MB。

```
菜单栏预览：
  ● C  16%    ● G   8%    ● M  61%
   青色 CPU     紫色 GPU     绿色 内存
```

## 为什么做这个项目

macOS 上知名的菜单栏监控工具（如 MenuMeters 原版、iStat Menus）要么年久失修、要么商业收费、要么基于 Electron 体积臃肿。本项目用纯原生技术栈重写，目标是：

- **极小体积**：编译产物约 356 KB，安装包（DMG）约 244 KB
- **极低占用**：常驻内存约 15 MB，采样在内核态 API 完成，不启动任何外部进程
- **零依赖**：只用 Apple 官方框架，无 CocoaPods / SPM 第三方库
- **现代简洁**：彩色圆点 + 等宽数字，自动适配浅色 / 深色菜单栏，数值平滑不跳动

## 功能特性

- 顶部菜单栏实时显示三项指标（采样周期 1.5 秒，带指数平滑）
- 点击任意指标弹出菜单，查看详细数值（含内存已用 / 总量 GB）
- 菜单内一键开启 / 关闭**开机自启**（通过用户级 LaunchAgent）
- 单实例保护，重复启动不会产生多个图标
- 纯菜单栏应用（不显示 Dock 图标）
- 内置 `--print-once` 调试模式，便于验证采样准确性

## 平台支持与限制

| 指标 | 实现方式 | Intel Mac | Apple Silicon |
|------|----------|-----------|---------------|
| CPU | Mach `host_processor_info` 差分采样 | ✅ | ✅ |
| 内存 | Mach `host_statistics64` | ✅ | ✅ |
| GPU | IOKit `IOAccelerator` 性能统计 | ✅ | ⚠️ 通常读到 0 |

> **GPU 限制说明**：Apple 的 `IOAccelerator`  utilization 字段仅在**Intel 核显**驱动上暴露。Apple Silicon（M1/M2/M3/M4）不提供该字段，GPU 项会显示 0。如需在 Apple Silicon 上支持 GPU 监控，需改用 `powermetrics`（需 root 权限）或其他方案——欢迎 PR。

- 最低系统版本：**macOS 12.0 (Monterey)**
- 已在 macOS 12.7.6 + Intel Xeon / HD Graphics P530 上验证

## 安装

### 方式一：下载现成安装包（推荐）

前往 [Releases](../../releases) 下载 `MenuMeters.dmg`，双击挂载后把 App 拖入「应用程序」即可。

> 本项目为 **ad-hoc 签名、未经 Apple 公证**。首次打开若提示"来自身份不明的开发者"：
> 打开 `系统设置 → 隐私与安全性` → 点「仍要打开」。
> 或在终端执行 `xattr -cr /Applications/MenuMeters.app` 移除隔离属性。
>
> 想彻底消除提示需要加入 Apple Developer Program（$99/年）做正式签名与公证。对这类小工具通常没必要。

### 方式二：从源码构建

只需 Command Line Tools（无需完整 Xcode）：

```bash
# 安装 Command Line Tools（若尚未安装）
xcode-select --install

git clone https://github.com/a2109246162-tech/MenuMeters-Swift.git
cd MenuMeters-Swift

# 生成图标（首次构建需要）
swift scripts/make_icon.swift
iconutil -c icns output/MenuMeters.iconset -o output/MenuMeters.icns

# 编译 App
bash scripts/build.sh
```

产物位于 `output/MenuMeters.app`，可直接双击运行或拖入「应用程序」。

脚本使用**相对路径**（基于脚本自身位置推导），clone 到任意目录都能正常构建。

## 用法

- **查看数值**：菜单栏右上角的 `C / G / M` 三个百分比即为实时占用率
- **详细菜单**：点击任一指标 → 显示三项占用率与内存用量明细
- **开机自启**：点击菜单栏图标 →「开启开机自启」。会写入 `~/Library/LaunchAgents/com.stackmaster.menumeters.plist`，登录时自动运行
- **验证采样**：终端运行 `MenuMeters.app/Contents/MacOS/MenuMeters --print-once`，打印一次采样值后退出

## 卸载

1. 菜单栏点击 →「开机自启已开启（点击关闭）」（如果开过自启）
2. 菜单栏点击 →「退出 MenuMeters」
3. 删除 `/Applications/MenuMeters.app`
4. 若仍残留，删除 `~/Library/LaunchAgents/com.stackmaster.menumeters.plist`

## 技术实现

| 模块 | 关键 API |
|------|----------|
| CPU | `host_processor_info(HOST_CPU_LOAD_INFO)` 两次采样差分 |
| GPU | IOKit `IOServiceMatching("IOAccelerator")` → `PerformanceStatistics["Device Utilization %"]` |
| 内存 | `host_statistics64(HOST_VM_INFO64)`，按 `(wired + active + compressed) / physical` 计算 |
| 菜单栏 | AppKit `NSStatusBar` / `NSStatusItem`，富文本 `attributedTitle` |
| 自启 | 用户级 LaunchAgent plist，通过 `launchctl bootstrap` 注册 |
| 界面 | 纯代码，无 Storyboard / XIB |

源码结构：

```
.
├── src/
│   ├── main.swift        # 全部逻辑（采样器 + 菜单栏 + 自启）
│   └── Info.plist        # App 配置（LSUIElement 等）
├── scripts/
│   ├── make_icon.swift   # 生成 .icns 图标
│   └── build.sh          # 一键编译打包
└── output/               # 构建产物（gitignore）
```

## 验证与测试

数据准确性可对照系统工具：

```bash
# CPU：对比 top 的 idle 值（占用率 ≈ 100 - idle）
top -l 2 | grep "CPU usage"

# GPU：对比 IOKit 原始值
ioreg -r -c IOAccelerator -l | grep "Device Utilization %"

# 内存：对比 vm_stat（active + wired + compressor 页 × 页大小）
vm_stat
```

实测内存读数与 `vm_stat` 手算结果误差 < 0.1%。

## License

[MIT](LICENSE) — 自由使用、修改、分发，欢迎 Star 和 PR。

## 致谢

灵感来自经典工具 MenuMeters，用原生 Swift 重新实现，向原作者致敬。
