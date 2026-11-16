//  MenuMeters — 轻量级 macOS 菜单栏系统资源监控
//  技术栈：Swift 5 + AppKit + IOKit + Mach API（无第三方依赖）
//  目标：CPU / GPU / 内存占用率实时显示于顶部菜单栏，低 CPU / 低内存开销

import AppKit
import IOKit
import Darwin

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

/// 管理三个 NSStatusItem，定时采样并刷新显示，提供下拉菜单与开机自启开关。
final class MenuBarController: NSObject, NSMenuDelegate {

    private let metrics = SystemMetrics()
    private var statusItems: [NSStatusItem] = []
    private var values: [Double] = [0, 0, 0]
    private var timer: Timer?

    private let fullTitles = ["CPU 占用", "GPU 占用", "内存占用"]
    private let shortTags  = ["C", "G", "M"]

    /// 三项指标的主题色：青 / 紫 / 绿，现代简洁风格
    private let accents: [NSColor] = [
        NSColor(red: 0.25, green: 0.72, blue: 0.95, alpha: 1.0),
        NSColor(red: 0.62, green: 0.45, blue: 0.96, alpha: 1.0),
        NSColor(red: 0.30, green: 0.84, blue: 0.56, alpha: 1.0)
    ]

    // LaunchAgent 配置：macOS 12 上使用用户级 LaunchAgent 实现开机自启
    private let agentLabel = "com.stackmaster.menumeters"
    private var agentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.stackmaster.menumeters.plist"
    }

    override init() {
        super.init()
        for _ in 0..<3 {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItems.append(item)
        }
    }

    /// 立即采样一次，随后启动 1.5 秒周期的定时器（带容差，便于系统节能）。
    func start() {
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.sample()
        }
        t.tolerance = 0.3
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
            .foregroundColor: accents[index],
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
        button.toolTip = "\(fullTitles[index]): \(percent)%"
    }

    // MARK: 下拉菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "MenuMeters · 系统资源监控", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
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
