//  MenuMeters — 轻量级 macOS 菜单栏系统资源监控
//  技术栈：Swift 5 + AppKit + IOKit + Mach API（无第三方依赖）
//  目标：CPU / GPU / 内存占用率实时显示于顶部菜单栏，低 CPU / 低内存开销
//  v1.1.0：新增设置功能 —— 右键任一项可单独更改圆点颜色（8 预设 + 自定义），
//          左键菜单可调整刷新间隔、显示/隐藏各项、恢复默认配色

import AppKit
import IOKit
import Darwin

// MARK: - 设置持久化

/// 基于 UserDefaults 的轻量设置层：颜色、刷新间隔、显示开关均持久化保存。
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// 三项指标的默认主题色：青 / 紫 / 绿
    static let defaultColors: [NSColor] = [
        NSColor(red: 0.25, green: 0.72, blue: 0.95, alpha: 1.0),
        NSColor(red: 0.62, green: 0.45, blue: 0.96, alpha: 1.0),
        NSColor(red: 0.30, green: 0.84, blue: 0.56, alpha: 1.0)
    ]

    /// 右键设置菜单提供的 8 种预设色
    static let presetColors: [(name: String, color: NSColor)] = [
        ("天青", NSColor(red: 0.25, green: 0.72, blue: 0.95, alpha: 1.0)),
        ("紫罗兰", NSColor(red: 0.62, green: 0.45, blue: 0.96, alpha: 1.0)),
        ("翠绿", NSColor(red: 0.30, green: 0.84, blue: 0.56, alpha: 1.0)),
        ("暖橙", NSColor(red: 1.00, green: 0.60, blue: 0.20, alpha: 1.0)),
        ("朱红", NSColor(red: 0.95, green: 0.35, blue: 0.35, alpha: 1.0)),
        ("明黄", NSColor(red: 0.98, green: 0.80, blue: 0.25, alpha: 1.0)),
        ("樱粉", NSColor(red: 0.95, green: 0.45, blue: 0.75, alpha: 1.0)),
        ("湖蓝", NSColor(red: 0.30, green: 0.85, blue: 0.85, alpha: 1.0))
    ]

    /// 可选刷新间隔（秒）
    static let intervalOptions: [Double] = [1.0, 1.5, 3.0, 5.0]

    // MARK: 颜色

    func color(for index: Int) -> NSColor {
        if let data = defaults.data(forKey: "accentColor.\(index)"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return Settings.defaultColors[index]
    }

    func setColor(_ color: NSColor, for index: Int) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            defaults.set(data, forKey: "accentColor.\(index)")
        }
    }

    func resetColor(_ index: Int) {
        defaults.removeObject(forKey: "accentColor.\(index)")
    }

    func resetAllColors() {
        for i in 0..<3 { resetColor(i) }
    }

    /// 按 sRGB 分量比较颜色（用于给当前色打勾），避免色彩空间差异导致误判
    static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let f: (CGFloat) -> Int = { Int(($0 * 255).rounded()) }
        return f(x.redComponent) == f(y.redComponent)
            && f(x.greenComponent) == f(y.greenComponent)
            && f(x.blueComponent) == f(y.blueComponent)
    }

    // MARK: 刷新间隔

    var refreshInterval: Double {
        get {
            let value = defaults.double(forKey: "refreshInterval")
            return value > 0 ? value : 1.5
        }
        set { defaults.set(newValue, forKey: "refreshInterval") }
    }

    // MARK: 显示开关

    func isVisible(_ index: Int) -> Bool {
        defaults.object(forKey: "visible.\(index)") as? Bool ?? true
    }

    func setVisible(_ visible: Bool, for index: Int) {
        defaults.set(visible, forKey: "visible.\(index)")
    }
}

// MARK: - 系统指标采样器

/// 负责从系统底层读取 CPU / GPU / 内存占用率。
/// 所有读取均为内核态 API 调用，单次耗时在微秒级，不 spawn 外部进程。
final class SystemMetrics {

    // 上一次 CPU 采样的累计 tick，用于计算两次采样之间的差值
    private var lastCPUTicks: (idle: Double, total: Double)?

    // MARK: CPU

    /// 通过 Mach `host_processor_info` 读取每个核心的 tick 计数，
    /// 用两次采样的 (总时间 - 空闲时间) / 总时间 得到占用率。
    /// 首次调用返回 0（尚无对比基准），之后每次调用提供上一次采样以来均值。
    func cpuUsage() -> Double {
        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let info = cpuInfo, infoCount > 0 else { return 0 }
        defer {
            // host_processor_info 分配了内存，必须手动释放，避免内存泄漏
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        let buffer = UnsafeBufferPointer(start: info, count: Int(infoCount))
        var idle: Double = 0
        var total: Double = 0

        for core in 0..<Int(processorCount) {
            let base = core * Int(CPU_STATE_MAX)
            guard base + 3 < buffer.count else { continue }
            let user = Double(buffer[base + Int(CPU_STATE_USER)])
            let sys  = Double(buffer[base + Int(CPU_STATE_SYSTEM)])
            let idl  = Double(buffer[base + Int(CPU_STATE_IDLE)])
            let nice = Double(buffer[base + Int(CPU_STATE_NICE)])
            idle += idl
            total += user + sys + idl + nice
        }

        var usage: Double = 0
        if let previous = lastCPUTicks {
            let deltaIdle  = idle - previous.idle
            let deltaTotal = total - previous.total
            if deltaTotal > 0 {
                usage = (1.0 - deltaIdle / deltaTotal) * 100.0
            }
        }
        lastCPUTicks = (idle, total)
        return max(0, min(100, usage))
    }

    // MARK: GPU

    /// 通过 IOKit 读取 `IOAccelerator` 服务的 `PerformanceStatistics` 字典，
    /// 取 "Device Utilization %" 作为 GPU 占用率。
    /// 该方法在搭载 Intel 核显的 Mac 上有效且无需额外权限；
    /// Apple Silicon 机型因驱动不暴露该字段会读到 0，需改用 powermetrics。
    func gpuUsage() -> Double {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var peak: Double = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let cfObject = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            ), let stats = cfObject.takeRetainedValue() as? [String: Any] {
                // 优先取整体利用率，部分驱动只有单单元计数值，作为兜底
                let value: Double = (stats["Device Utilization %"] as? NSNumber)?
                    .doubleValue
                    ?? (stats["Device Unit 0 Utilization %"] as? NSNumber)?.doubleValue
                    ?? 0
                peak = max(peak, value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return max(0, min(100, peak))
    }

    // MARK: 内存

    /// 通过 Mach `host_statistics64` 读取页面计数，按
    /// (wired + active + compressed) / 物理内存 计算已用百分比。
    /// 这比简单的 "已用 = 总量 - 空闲" 更贴近 macOS 活动监视器的语义。
    func memoryUsage() -> (percent: Double, usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(
                    mach_host_self(),
                    host_flavor_t(HOST_VM_INFO64),
                    intPointer,
                    &count
                )
            }
        }

        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS, totalBytes > 0 else { return (0, 0, 0) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Double(pageSize)

        let wired     = Double(stats.wire_count)           * page
        let active    = Double(stats.active_count)         * page
        let compressed = Double(stats.compressor_page_count) * page
        let usedBytes = wired + active + compressed

        let percent = max(0, min(100, usedBytes / totalBytes * 100.0))
        let gb = 1024.0 * 1024.0 * 1024.0
        return (percent, usedBytes / gb, totalBytes / gb)
    }
}

// MARK: - 菜单栏控制器

/// 管理三个 NSStatusItem。
/// 每个状态项挂一个原生 NSMenu —— 系统保证左键/右键点击都会弹出，不做任何左右键区分，
/// 颜色设置直接作为菜单里的「圆点颜色」子菜单，确保一定找得到、点得到。
final class MenuBarController: NSObject, NSMenuDelegate {

    private let metrics = SystemMetrics()
    private var statusItems: [NSStatusItem] = []
    private var menus: [NSMenu] = []
    private var values: [Double] = [0, 0, 0]
    private var timer: Timer?

    /// 正在用颜色面板编辑的项索引
    private var editingColorIndex: Int?

    private let fullTitles = ["CPU 占用", "GPU 占用", "内存占用"]
    private let shortTags  = ["C", "G", "M"]

    // LaunchAgent 配置：用户级 LaunchAgent 实现开机自启
    private let agentLabel = "com.stackmaster.menumeters.lite"
    private var agentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.stackmaster.menumeters.lite.plist"
    }

    /// 菜单项携带的动作信息（避免用 tag 编码造成错位）
    private final class ColorAction: NSObject {
        let index: Int
        let preset: Int      // -1 表示自定义颜色
        init(index: Int, preset: Int) {
            self.index = index
            self.preset = preset
        }
    }

    override init() {
        super.init()
        for index in 0..<3 {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            // 关键：挂上原生菜单，AppKit 保证点击（左/右键）都能弹出
            item.menu = menu
            item.isVisible = Settings.shared.isVisible(index)
            statusItems.append(item)
            menus.append(menu)
        }
    }

    /// 立即采样一次，随后按设置里的间隔启动周期定时器。
    func start() {
        sample()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = Settings.shared.refreshInterval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        let fresh = [metrics.cpuUsage(), metrics.gpuUsage(), metrics.memoryUsage().percent]
        for i in 0..<3 {
            values[i] = values[i] * 0.5 + fresh[i] * 0.5
            render(i)
        }
    }

    /// 富文本绘制：彩色圆点 + 标签 + 等宽数字。
    private func render(_ index: Int) {
        guard let button = statusItems[index].button else { return }
        let percent = Int(values[index].rounded())

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "●", attributes: [
            .foregroundColor: Settings.shared.color(for: index),
            .font: NSFont.systemFont(ofSize: 9)
        ]))
        title.append(NSAttributedString(
            string: " \(shortTags[index]) \(String(format: "%3d", percent))%",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ]
        ))
        button.attributedTitle = title
        button.toolTip = "\(fullTitles[index]): \(percent)%（点此菜单可改颜色）"
    }

    // MARK: - 菜单

    /// 菜单每次打开前重新构建（数值、打勾状态都是最新的）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let index = menus.firstIndex(where: { $0 === menu }), index < 3 else { return }
        menu.removeAllItems()

        menu.addItem(nonAction("MenuMeters Lite · 轻量系统监控"))
        menu.addItem(nonAction("提示：在「圆点颜色」里可单独改这一项"))
        menu.addItem(NSMenuItem.separator())

        // 三项实时数值
        let memory = metrics.memoryUsage()
        let detailLines = [
            "\(fullTitles[0])  \(Int(values[0].rounded()))%",
            "\(fullTitles[1])  \(Int(values[1].rounded()))%",
            "\(fullTitles[2])  \(Int(values[2].rounded()))%  (\(String(format: "%.1f", memory.usedGB)) / \(String(format: "%.1f", memory.totalGB)) GB)"
        ]
        detailLines.forEach { menu.addItem(nonAction($0)) }
        menu.addItem(NSMenuItem.separator())

        // ── 圆点颜色（核心功能，直接放在一级菜单，绝不藏起来）──
        let colorItem = NSMenuItem(title: "圆点颜色", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        let current = Settings.shared.color(for: index)
        for (p, preset) in Settings.presetColors.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPresetColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ColorAction(index: index, preset: p)
            let dot = NSMutableAttributedString(string: "●  ", attributes: [
                .foregroundColor: preset.color, .font: NSFont.systemFont(ofSize: 11)
            ])
            dot.append(NSAttributedString(string: preset.name, attributes: [
                .foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 14)
            ]))
            item.attributedTitle = dot
            item.state = Settings.sameColor(current, preset.color) ? .on : .off
            colorMenu.addItem(item)
        }
        colorMenu.addItem(NSMenuItem.separator())
        let custom = NSMenuItem(title: "自定义颜色…", action: #selector(openColorPanel(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = ColorAction(index: index, preset: -1)
        colorMenu.addItem(custom)
        let reset = NSMenuItem(title: "恢复这一项默认颜色", action: #selector(resetColor(_:)), keyEquivalent: "")
        reset.target = self
        reset.representedObject = ColorAction(index: index, preset: -2)
        colorMenu.addItem(reset)
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // ── 设置 ──
        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for option in Settings.intervalOptions {
            let label = option == Double(Int(option)) ? "\(Int(option)) 秒" : "\(option) 秒"
            let item = NSMenuItem(title: label, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = abs(Settings.shared.refreshInterval - option) < 0.01 ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        settingsMenu.addItem(intervalItem)

        let visibleItem = NSMenuItem(title: "显示项目", action: nil, keyEquivalent: "")
        let visibleMenu = NSMenu()
        for i in 0..<3 {
            let item = NSMenuItem(title: fullTitles[i], action: #selector(toggleVisible(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = Settings.shared.isVisible(i) ? .on : .off
            visibleMenu.addItem(item)
        }
        visibleItem.submenu = visibleMenu
        settingsMenu.addItem(visibleItem)

        let resetAll = NSMenuItem(title: "恢复所有默认颜色", action: #selector(resetAllColors), keyEquivalent: "")
        resetAll.target = self
        settingsMenu.addItem(resetAll)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let autoTitle = isAutoLaunchEnabled() ? "✓ 开机自启已开启（点击关闭）" : "开启开机自启"
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(toggleAutoLaunch), keyEquivalent: "")
        autoItem.target = self
        menu.addItem(autoItem)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出 MenuMeters Lite", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func nonAction(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 颜色动作

    @objc private func applyPresetColor(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ColorAction, action.preset >= 0,
              action.preset < Settings.presetColors.count else { return }
        Settings.shared.setColor(Settings.presetColors[action.preset].color, for: action.index)
        render(action.index)
    }

    @objc private func openColorPanel(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ColorAction else { return }
        editingColorIndex = action.index
        let panel = NSColorPanel.shared
        panel.color = Settings.shared.color(for: action.index)
        NotificationCenter.default.removeObserver(self, name: NSColorPanel.colorDidChangeNotification, object: panel)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(colorPanelChanged(_:)),
                                               name: NSColorPanel.colorDidChangeNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(colorPanelClosed(_:)),
                                               name: NSWindow.willCloseNotification, object: panel)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ notification: Notification) {
        guard let index = editingColorIndex,
              let panel = notification.object as? NSColorPanel else { return }
        Settings.shared.setColor(panel.color, for: index)
        render(index)
    }

    @objc private func colorPanelClosed(_ notification: Notification) {
        guard let panel = notification.object as? NSColorPanel else { return }
        editingColorIndex = nil
        NotificationCenter.default.removeObserver(self, name: NSColorPanel.colorDidChangeNotification, object: panel)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func resetColor(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ColorAction else { return }
        Settings.shared.resetColor(action.index)
        render(action.index)
    }

    @objc private func resetAllColors() {
        Settings.shared.resetAllColors()
        for i in 0..<3 { render(i) }
    }

    // MARK: - 其它设置

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        Settings.shared.refreshInterval = interval
        restartTimer()
    }

    @objc private func toggleVisible(_ sender: NSMenuItem) {
        let index = sender.tag
        let target = !Settings.shared.isVisible(index)
        let visibleCount = (0..<3).filter { Settings.shared.isVisible($0) }.count
        if !target && visibleCount <= 1 { return }
        Settings.shared.setVisible(target, for: index)
        statusItems[index].isVisible = target
    }

    // MARK: - 开机自启

    private func isAutoLaunchEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPath)
    }

    @objc private func toggleAutoLaunch() {
        let uid = getuid()
        if isAutoLaunchEnabled() {
            runLaunchctl(["bootout", "gui/\(uid)", agentPath])
            try? FileManager.default.removeItem(atPath: agentPath)
        } else {
            let appPath = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>\(agentLabel)</string>
              <key>ProgramArguments</key>
              <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(appPath)</string>
              </array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><false/>
            </dict>
            </plist>
            """
            do {
                try plist.write(toFile: agentPath, atomically: true, encoding: .utf8)
                runLaunchctl(["bootstrap", "gui/\(uid)", agentPath])
            } catch { /* 静默处理，下次打开菜单反映真实状态 */ }
        }
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 自检

    /// 验证菜单已挂载、颜色子菜单齐全、改色能实时反映到状态栏元素。
    func selfTestColors() {
        // 1. 菜单挂载
        let menuOK = menus.count == 3 && zip(statusItems, menus).allSatisfy { $0.0.menu === $0.1 }
        print("SELFTEST_MENU=\(menuOK ? "PASS" : "FAIL")")

        // 2. 模拟打开菜单，确认「圆点颜色」子菜单存在且有 8+ 个可点项
        menuNeedsUpdate(menus[0])
        guard let colorItem = menus[0].items.first(where: { $0.title == "圆点颜色" }),
              let sub = colorItem.submenu else {
            print("SELFTEST_COLORMENU=FAIL reason=no-color-submenu")
            return
        }
        let actionable = sub.items.filter { $0.action != nil && $0.isEnabled }.count
        print("SELFTEST_COLORMENU=\(actionable >= 10 ? "PASS" : "FAIL") actionable=\(actionable)")

        // 3. 改色 → 渲染
        let expected = Settings.presetColors[4].color
        Settings.shared.setColor(expected, for: 0)
        render(0)
        let actual = statusItems[0].button?.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let ok = actual.map { Settings.sameColor($0, expected) } ?? false
        print("SELFTEST_COLORAPPLY=\(ok ? "PASS" : "FAIL")")
        Settings.shared.resetColor(0)
        render(0)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护：已有同 bundle id 的实例在运行时直接退出，避免重复图标
        let bundleId = Bundle.main.bundleIdentifier ?? "com.stackmaster.menumeters.lite"
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != getpid() }
        if !duplicates.isEmpty {
            NSApp.terminate(nil)
            return
        }

        controller = MenuBarController()
        controller?.start()

        // 自检模式：验证颜色设置链路后退出
        if CommandLine.arguments.contains("--self-test") {
            controller?.selfTestColors()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - 程序入口

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)  // 纯菜单栏应用，不显示 Dock 图标

// 调试模式：`MenuMeters --print-once` 打印一次采样值后退出，便于验证数据准确性
if CommandLine.arguments.contains("--print-once") {
    let probe = SystemMetrics()
    _ = probe.cpuUsage()             // 第一次调用建立 CPU 基准
    usleep(300_000)                  // 间隔 300ms 后取有效值
    let cpu = probe.cpuUsage()
    let gpu = probe.gpuUsage()
    let mem = probe.memoryUsage()
    print(String(
        format: "CPU=%.1f%%  GPU=%.1f%%  MEM=%.1f%%  (%.2f / %.2f GB)",
        cpu, gpu, mem.percent, mem.usedGB, mem.totalGB
    ))
    exit(0)
}

app.run()
