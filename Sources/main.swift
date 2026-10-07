import AppKit
import IOKit.ps


struct Mode {
    let name: String
    let detail: String
    let ac: Bool
    let value: Int
    var arguments: [String] { [ac ? "-c" : "-b", "powermode", String(value)] }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let modes = [
        Mode(name: "插电 · 极致性能", detail: "高电量模式 · 大模型 / 视频剪辑", ac: true, value: 2),
        Mode(name: "插电 · 普通均衡", detail: "自动模式 · 系统平衡性能、温度与噪音", ac: true, value: 0),
        Mode(name: "离电 · 高性能", detail: "高电量模式 · 更耗电，保留系统保护", ac: false, value: 2),
        Mode(name: "离电 · 轻度工作", detail: "低电量模式 · 码字 / 浏览 / 聊天 / 影音", ac: false, value: 1)
    ]
    let worker = DispatchQueue(label: "local.macpowermodes.operations", qos: .utility)
    var supportsHighPower = false
    var menuOpen = false
    var adapterWatts: Int?
    var item: NSStatusItem!
    var source: CFRunLoopSource?
    var busy = false
    var settings = PowerSettings()
    var onAC = true
    var batteryPercent: Int?
    var status = "点击模式配置对应电源；插拔电源由系统自动切换。"

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Mac 能耗模式")
        item.menu = NSMenu()
        item.menu?.delegate = self
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let previousSource = delegate.onAC
            delegate.updatePower()
            if previousSource != delegate.onAC { delegate.refreshSettings() }
            if delegate.menuOpen { delegate.rebuildMenu() }
        }
        source = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        updatePower()
        rebuildMenu()
        refreshSettings()
    }
    @objc func thermalChanged() { if menuOpen { rebuildMenu() } }
    @objc func wokeUp() { updatePower(); refreshSettings() }
    func refreshSettings() {
        guard !busy else { return }
        worker.async { [self] in
            let refreshed = readSettings()
            let highPower = readHighPowerSupport()
            DispatchQueue.main.async { [self] in
                settings = refreshed
                supportsHighPower = highPower
                updatePower()
                if menuOpen { rebuildMenu() }
            }
        }
    }
    func updatePower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        onAC = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
        batteryPercent = nil
        adapterWatts = nil
        if onAC, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }
        if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for power in sources {
                if let description = IOPSGetPowerSourceDescription(info, power)?.takeUnretainedValue() as? [String: Any],
                   let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    batteryPercent = current * 100 / max
                }
            }
        }
        let value = settings.value(forAC: onAC)
        item.button?.title = value == 2 ? " 高" : value == 1 ? " 省" : value == 0 ? " 自动" : " 未知"
        item.button?.toolTip = "Mac 能耗模式 · \(onAC ? "插电" : "电池供电")"
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        updatePower()
        rebuildMenu()
        refreshSettings()
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    func label(_ text: String, menu: NSMenu) {
        let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        row.isEnabled = false
        menu.addItem(row)
    }
    func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()
        label("Mac 能耗模式", menu: menu)
        label("\(onAC ? "⚡ 插电" : "🔋 电池供电") · 电量 \(batteryPercent.map { "\($0)%" } ?? "未知")", menu: menu)
        if onAC { label("适配器供电能力：\(adapterWatts.map { "\($0) W" } ?? "未知") · 非实时耗电", menu: menu) }
        label("当前生效：\(onAC ? "插电" : "离电")策略", menu: menu)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "正常"
        case .fair: thermal = "温热"
        case .serious: thermal = "较高 · 系统保护中"
        case .critical: thermal = "很高 · 系统保护中"
        @unknown default: thermal = "未知"
        }
        label("系统热状态：\(thermal)", menu: menu)
        menu.addItem(.separator())
        for (index, mode) in modes.enumerated() {
            let row = NSMenuItem(title: mode.name, action: #selector(selectMode(_:)), keyEquivalent: "")
            row.target = self
            row.tag = index
            row.state = settings.value(forAC: mode.ac) == mode.value ? .on : .off
            row.isEnabled = !busy && settings.value(forAC: mode.ac) != nil && (mode.value != 2 || supportsHighPower)
            menu.addItem(row)
            label("    \(mode.detail)", menu: menu)
        }
        if !supportsHighPower { label("本机未报告高电量模式支持；性能选项暂不可用。", menu: menu) }
        menu.addItem(.separator())
        label(busy ? "正在处理电源设置…" : status, menu: menu)
        label("仅配置电源策略；不会退出、暂停或关闭应用和项目。", menu: menu)
        label("两种电源分别记忆设置；退出本软件后仍生效。", menu: menu)
        let reset = NSMenuItem(title: "两种电源均恢复自动模式…", action: #selector(resetSettings), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = !busy
        menu.addItem(reset)
        let access = NSMenuItem(title: PowerAuthorization.installed ? "撤销免密切换…" : "启用首次授权免密切换…", action: #selector(toggleAuthorization), keyEquivalent: "")
        access.target = self
        access.isEnabled = !busy
        menu.addItem(access)
        let battery = NSMenuItem(title: "打开系统电池设置", action: #selector(openBattery), keyEquivalent: "")
        battery.target = self
        menu.addItem(battery)
        let about = NSMenuItem(title: "使用说明", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Mac 能耗模式", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = !busy
        menu.addItem(quit)
    }
    @objc func selectMode(_ sender: NSMenuItem) {
        let mode = modes[sender.tag]
        apply(arguments: mode.arguments, expectedAC: mode.ac ? mode.value : nil, expectedBattery: mode.ac ? nil : mode.value, message: "已配置：\(mode.name)\(mode.ac == onAC ? "" : "（切换至该电源时生效）")")
    }
    @objc func resetSettings() {
        apply(arguments: ["-a", "powermode", "0"], expectedAC: 0, expectedBattery: 0, message: "插电与离电均已恢复自动模式。")
    }
    func apply(arguments: [String], expectedAC: Int?, expectedBattery: Int?, message: String) {
        guard !busy else { return }
        busy = true
        rebuildMenu()
        worker.async { [self] in
            let before = readSettings()
            let alreadyApplied = before.matches(ac: expectedAC, battery: expectedBattery)
            let result = alreadyApplied ? CommandResult(code: 0, output: "") : PowerAuthorization.apply(arguments)
            let newSettings = alreadyApplied ? before : readSettings()
            let verified = newSettings.matches(ac: expectedAC, battery: expectedBattery)
            DispatchQueue.main.async { [self] in
                settings = newSettings
                busy = false
                if result.code == -128 { status = "已取消授权，未由本软件应用设置。" }
                else if result.code != 0 { status = "应用失败；请查看错误详情。"; showError(result.output) }
                else if !verified { status = "设置未通过回读验证。"; showError("macOS 未返回预期模式，请在系统电池设置中核对。") }
                else { status = alreadyApplied ? "该策略已生效，无需重复应用。" : message }
                updatePower()
                rebuildMenu()
            }
        }
    }
    @objc func toggleAuthorization() {
        guard !busy else { return }
        let remove = PowerAuthorization.installed
        busy = true
        rebuildMenu()
        worker.async { [self] in
            let result = remove ? PowerAuthorization.uninstall() : PowerAuthorization.install()
            DispatchQueue.main.async { [self] in
                busy = false
                if result.code == -128 { status = "已取消系统授权。" }
                else if result.code != 0 { status = "权限设置失败。"; showError(result.output) }
                else { status = remove ? "已撤销；下次切换需要重新授权。" : "首次授权完成，之后切换无需输入密码。" }
                rebuildMenu()
            }
        }
    }
    func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法确认电源模式"
        alert.informativeText = text
        alert.runModal()
    }
    @objc func openBattery() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!) }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "四种场景，系统原生电源策略"
        alert.informativeText = "插电性能与离电性能使用系统高电量模式；普通模式使用自动；轻度工作使用低电量。\n\n高电量模式提供更积极的散热，实际提升取决于负载，不能保证始终满功耗。离电高性能更耗电，无法承诺电池零损耗。系统温控、充电和电池保护保持生效。\n\n切换需要系统授权；启用菜单中的免密切换后无需重复输入。软件不保存密码；当前账户获得五个固定电源命令的权限，也适用于该账户的其他程序。可在菜单中撤销。插电与离电独立保存，系统自动切换。本软件没有持续性能采样、网络连接或后台提权服务。\n\n建议在系统设置中开启优化电池充电。14 英寸 M4 Pro 使用高电量模式充电时，Apple 建议 96W 电源适配器。"
        alert.runModal()
    }
    @objc func quitApp() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--install-one-time") {
    let result = PowerAuthorization.install()
    print(result.output)
    exit(result.code == 0 ? 0 : 1)
} else if CommandLine.arguments.contains("--self-test") {
    let parsed = PowerSettings.parse("Battery Power:\n powermode 1\nAC Power:\n powermode 2\n")
    precondition(parsed.ac == 2 && parsed.battery == 1)
    precondition(PowerSettings.parse("unknown").ac == nil)
    let live = readSettings()
    precondition(live.ac != nil && live.battery != nil, "Unable to read system modes")
    print("PASS: source parsing, missing settings, live system read; AC=\(live.ac!), battery=\(live.battery!)")
} else {
    if let identifier = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != getpid() }) { exit(0) }
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
