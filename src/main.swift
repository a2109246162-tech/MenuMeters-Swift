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

/// 管理三个 NSStatusItem：左键弹出详情菜单，右键弹出该项的设置菜单（配色等）。
final class MenuBarController: NSObject {

    private let metrics = SystemMetrics()
    private var statusItems: [NSStatusItem] = []
    private var values: [Double] = [0, 0, 0]
    private var timer: Timer?

    /// 正在用颜色面板编辑的项索引
    private var editingColorIndex: Int?

    private let fullTitles = ["CPU 占用", "GPU 占用", "内存占用"]
    private let shortTags  = ["C", "G", "M"]

    // LaunchAgent 配置：macOS 12 上使用用户级 LaunchAgent 实现开机自启
    private let agentLabel = "com.stackmaster.menumeters"
    private var agentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.stackmaster.menumeters.plist"
    }

    override init() {
        super.init()
        for _ in 0..<3 {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // 用 button 的 target/action 显式区分左右键，不用 item.menu + delegate
            // （menuNeedsUpdate 里 NSApp.currentEvent 已非原始鼠标事件，判断不可靠）
            if let button = item.button {
                button.target = self
                button.action = #selector(statusItemClicked(_:event:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            item.isVisible = Settings.shared.isVisible(statusItems.count)
            statusItems.append(item)
        }
    }

    /// 状态栏项被点击：直接使用传入的事件判断左右键（最可靠，不依赖 NSApp.currentEvent）。
    @objc private func statusItemClicked(_ sender: NSStatusBarButton, event: NSEvent) {
        guard let index = statusItems.firstIndex(where: { $0.button === sender }) else { return }
        let isRight = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        let menu = isRight ? makeSettingsMenu(for: index) : makeDetailMenu(for: index)
        // 菜单栏按钮为 flipped 坐标：bounds.height 对应按钮底边（屏幕下方），
        // 让菜单顶边对齐按钮底边，从菜单栏下方弹出，模拟原生效果。
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// 立即采样一次，随后按设置里的间隔启动周期定时器（带容差，便于系统节能）。
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
            // 指数平滑，避免数字快速跳动造成视觉噪音
            values[i] = values[i] * 0.5 + fresh[i] * 0.5
            render(i)
        }
    }

    /// 用富文本绘制菜单栏按钮：彩色圆点 + 标签 + 等宽数字，宽度稳定不跳动。
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
                .foregroundColor: NSColor.labelColor,  // 自适应浅色/深色菜单栏
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ]
        ))
        button.attributedTitle = title
        button.toolTip = "\(fullTitles[index]): \(percent)%（右键可设置颜色）"
    }

    // MARK: 菜单构建（左键详情 / 右键设置）

    /// 左键：全局详情菜单 + 设置入口
    private func makeDetailMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "MenuMeters · 系统资源监控 v1.1", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let hint = NSMenuItem(title: "右键任一项可单独设置颜色", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem.separator())

        let memory = metrics.memoryUsage()
        let detailLines = [
            "\(fullTitles[0])  \(Int(values[0].rounded()))%",
            "\(fullTitles[1])  \(Int(values[1].rounded()))%",
            "\(fullTitles[2])  \(Int(values[2].rounded()))%  (\(String(format: "%.1f", memory.usedGB)) / \(String(format: "%.1f", memory.totalGB)) GB)"
        ]
        for line in detailLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // 设置子菜单：刷新间隔 / 显示开关 / 恢复默认配色
        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: ",")
        let settingsMenu = NSMenu()

        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for option in Settings.intervalOptions {
            let label = option == Double(Int(option)) ? "\(Int(option)) 秒" : "\(option) 秒"
            let item = NSMenuItem(title: label, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            if abs(Settings.shared.refreshInterval - option) < 0.01 { item.state = .on }
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

        let resetColors = NSMenuItem(title: "恢复所有默认颜色", action: #selector(resetAllColors), keyEquivalent: "")
        resetColors.target = self
        settingsMenu.addItem(resetColors)

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let autoTitle = isAutoLaunchEnabled()
            ? "✓ 开机自启已开启（点击关闭）"
            : "开启开机自启"
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(toggleAutoLaunch), keyEquivalent: "")
        autoItem.target = self
        menu.addItem(autoItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 MenuMeters", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    /// 右键：仅针对被点击项的设置菜单（配色为主）
    private func makeSettingsMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "\(fullTitles[index]) · 设置", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let colorHeader = NSMenuItem(title: "圆点颜色", action: nil, keyEquivalent: "")
        colorHeader.isEnabled = false
        menu.addItem(colorHeader)

        let current = Settings.shared.color(for: index)
        for (presetIndex, preset) in Settings.presetColors.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPresetColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index * 100 + presetIndex   // 高两位存项索引，低两位存预设索引
            // 菜单项前缀一个对应颜色的圆点，所见即所得
            let dot = NSMutableAttributedString(string: "●  ", attributes: [
                .foregroundColor: preset.color,
                .font: NSFont.systemFont(ofSize: 11)
            ])
            dot.append(NSAttributedString(string: preset.name, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.menuFont(ofSize: 14)
            ]))
            item.attributedTitle = dot
            if Settings.sameColor(current, preset.color) { item.state = .on }
            menu.addItem(item)
        }

        let custom = NSMenuItem(title: "自定义颜色…", action: #selector(openColorPanel(_:)), keyEquivalent: "")
        custom.target = self
        custom.tag = index
        menu.addItem(custom)

        menu.addItem(NSMenuItem.separator())
        let reset = NSMenuItem(title: "恢复默认颜色", action: #selector(resetColor(_:)), keyEquivalent: "")
        reset.target = self
        reset.tag = index
        menu.addItem(reset)

        menu.addItem(NSMenuItem.separator())
        let visibleCount = (0..<3).filter { Settings.shared.isVisible($0) }.count
        let hide = NSMenuItem(title: "隐藏此项", action: #selector(hideItem(_:)), keyEquivalent: "")
        hide.target = self
        hide.tag = index
        // 至少保留一项可见，否则用户将找不到设置入口
        hide.isEnabled = visibleCount > 1
        menu.addItem(hide)
        return menu
    }

    // MARK: 设置动作

    @objc private func applyPresetColor(_ sender: NSMenuItem) {
        let index = sender.tag / 100
        let presetIndex = sender.tag % 100
        guard presetIndex < Settings.presetColors.count else { return }
        Settings.shared.setColor(Settings.presetColors[presetIndex].color, for: index)
        render(index)
    }

    @objc private func openColorPanel(_ sender: NSMenuItem) {
        editingColorIndex = sender.tag
        let panel = NSColorPanel.shared
        panel.color = Settings.shared.color(for: sender.tag)
        // 先移除旧观察者，避免重复打开面板时叠加监听
        NotificationCenter.default.removeObserver(self, name: NSColorPanel.colorDidChangeNotification, object: panel)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        // 通过系统通知监听取色变化（NSColorPanel 无 target/action 属性）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(colorPanelChanged(_:)),
            name: NSColorPanel.colorDidChangeNotification,
            object: panel
        )
        // 面板关闭后停止响应，避免误改颜色
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(colorPanelClosed(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )
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
        Settings.shared.resetColor(sender.tag)
        render(sender.tag)
    }

    @objc private func resetAllColors() {
        Settings.shared.resetAllColors()
        for i in 0..<3 { render(i) }
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        Settings.shared.refreshInterval = interval
        restartTimer()
    }

    @objc private func toggleVisible(_ sender: NSMenuItem) {
        let index = sender.tag
        let newValue = !Settings.shared.isVisible(index)
        // 至少保留一项可见
        let visibleCount = (0..<3).filter { Settings.shared.isVisible($0) }.count
        if !newValue && visibleCount <= 1 { return }
        Settings.shared.setVisible(newValue, for: index)
        statusItems[index].isVisible = newValue
    }

    @objc private func hideItem(_ sender: NSMenuItem) {
        let index = sender.tag
        let visibleCount = (0..<3).filter { Settings.shared.isVisible($0) }.count
        guard visibleCount > 1 else { return }
        Settings.shared.setVisible(false, for: index)
        statusItems[index].isVisible = false
    }

    // MARK: 开机自启

    private func isAutoLaunchEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPath)
    }

    @objc private func toggleAutoLaunch() {
        let uid = getuid()
        if isAutoLaunchEnabled() {
            // 先卸载服务，再删除配置文件
            runLaunchctl(["bootout", "gui/\(uid)", agentPath])
            try? FileManager.default.removeItem(atPath: agentPath)
        } else {
            // 用 /usr/bin/open -a 启动 .app bundle 更可靠（直接指向 bundle 路径在部分
            // macOS 版本上无法正确拉起）；KeepAlive=false 避免 open 命令退出后被反复重启
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
            } catch {
                // 写入失败时静默处理，菜单栏菜单下次打开会反映真实状态
            }
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

    // MARK: 自检（仅供 --self-test 模式调用）

    /// 在真实 AppKit 环境验证"设置颜色 → 渲染到状态栏"链路是否生效。
    func selfTestColors() {
        let targetIndex = 0
        // 选一个与默认色明显不同的预设色：朱红 (index 4)
        let presetIndex = 4
        let expected = Settings.presetColors[presetIndex].color
        applyPresetColorTag(index: targetIndex, presetIndex: presetIndex)

        guard let button = statusItems[targetIndex].button,
              let actual = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor else {
            print("SELFTEST=FAIL reason=no-attributed-color")
            return
        }
        let ok = Settings.sameColor(actual, expected)
            && Settings.sameColor(Settings.shared.color(for: targetIndex), expected)
        print("SELFTEST=\(ok ? "PASS" : "FAIL") applied=\(actual) expected=\(expected)")

        // 恢复默认，避免污染用户设置
        Settings.shared.resetColor(targetIndex)
        render(targetIndex)
    }

    /// applyPresetColor 的可直接调用版本（供自检使用，逻辑与 action 完全一致）
    private func applyPresetColorTag(index: Int, presetIndex: Int) {
        guard presetIndex < Settings.presetColors.count else { return }
        Settings.shared.setColor(Settings.presetColors[presetIndex].color, for: index)
        render(index)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护：已有同 bundle id 的实例在运行时直接退出，避免重复图标
        let bundleId = Bundle.main.bundleIdentifier ?? "com.stackmaster.menumeters"
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
