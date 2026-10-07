import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let worker = DispatchQueue(label: "local.macpowermodes.tasks", qos: .utility)
    let priority = TaskPriority()
    var item: NSStatusItem!
    var sessions: [PriorityLease] = []
    var menuOpen = false
    var busy = false
    var refreshing = false
    var status = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Mac 任务优先级")
        item.menu = NSMenu()
        item.menu?.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stateChanged), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stateChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        rebuildMenu()
    }
    @objc func stateChanged() { if menuOpen { rebuildMenu(); refreshSessions() } }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; rebuildMenu(); refreshSessions() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    func refreshSessions() {
        guard !busy && !refreshing && !sessions.isEmpty else { return }
        refreshing = true
        worker.async { [self] in
            priority.cleanupExpired()
            let snapshot = priority.leases
            DispatchQueue.main.async { [self] in
                refreshing = false
                if sessions != snapshot {
                    sessions = snapshot
                    if menuOpen { rebuildMenu() }
                    updateIcon()
                }
            }
        }
    }
    func updateIcon() {
        item.button?.title = sessions.isEmpty ? "" : " \(sessions.count)"
        item.button?.toolTip = sessions.isEmpty ? "Mac 任务优先级 · 无活动会话" : "Mac 任务优先级 · \(sessions.count) 个任务"
    }
    func compact(_ text: String, limit: Int = 32) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
    func label(_ title: String, menu: NSMenu, heading: Bool = false, tooltip: String? = nil) {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        row.toolTip = tooltip
        if heading { row.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]) }
        menu.addItem(row)
    }
    @discardableResult
    func action(_ title: String, selector: Selector, symbol: String? = nil, enabled: Bool = true, menu: NSMenu) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        row.target = self
        row.isEnabled = enabled
        if let symbol { row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(row)
        return row
    }
    func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()
        label("Mac 任务优先级", menu: menu, heading: true)
        label(sessions.isEmpty ? "选择任务，提高 CPU 调度优先级" : "正在调节 \(sessions.count) 个任务", menu: menu)
        menu.addItem(.separator())
        action("选择应用或任务…", selector: #selector(selectTask), symbol: "plus.circle", enabled: !busy, menu: menu)
        if !sessions.isEmpty {
            menu.addItem(.separator())
            label("活动任务", menu: menu, heading: true)
            for lease in sessions {
                let remaining = max(0, Int(ceil(lease.expires.timeIntervalSinceNow / 60)))
                let row = NSMenuItem(title: "\(compact(lease.name, limit: 20)) · \(remaining) 分钟", action: nil, keyEquivalent: "")
                row.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
                row.toolTip = lease.name
                let details = NSMenu()
                label(lease.name, menu: details, heading: true)
                label("PID \(lease.identity.pid) · nice \(lease.identity.nice) → \(lease.desired)", menu: details)
                label("仅此进程 · 不包含子进程", menu: details)
                details.addItem(.separator())
                let restore = action("结束并恢复原优先级", selector: #selector(restoreTask(_:)), symbol: "arrow.uturn.backward", enabled: !busy, menu: details)
                restore.tag = Int(lease.identity.pid)
                row.submenu = details
                menu.addItem(row)
            }
            action("结束全部并恢复", selector: #selector(restoreAll), symbol: "arrow.counterclockwise", enabled: !busy, menu: menu)
        }
        menu.addItem(.separator())
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "系统热状态正常"
        case .fair: thermal = "系统热状态：温热"
        case .serious: thermal = "系统热状态：较高 · 保护中"
        case .critical: thermal = "系统热状态：很高 · 保护中"
        @unknown default: thermal = "系统热状态未知"
        }
        label(thermal, menu: menu, tooltip: "系统热压力状态，不是温度测量；本软件不修改温控。")
        if busy || !status.isEmpty { label(busy ? "正在处理…" : compact(status), menu: menu, tooltip: status) }
        let preferences = NSMenuItem(title: "设置与说明", action: nil, keyEquivalent: "")
        preferences.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let settingsMenu = NSMenu()
        if TaskAuthorization.legacyPermissionExists {
            action("移除旧版电源免密权限…", selector: #selector(removeLegacy), symbol: "lock", enabled: !busy, menu: settingsMenu)
            settingsMenu.addItem(.separator())
        }
        label("30 分钟到期或退出软件后恢复", menu: settingsMenu)
        action("使用说明", selector: #selector(showAbout), symbol: "info.circle", menu: settingsMenu)
        preferences.submenu = settingsMenu
        menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = action("退出", selector: #selector(quitApp), enabled: !busy, menu: menu)
        quit.keyEquivalent = "q"
        updateIcon()
    }
    func perform(_ operation: @escaping () -> CommandResult) {
        guard !busy else { return }
        busy = true; rebuildMenu()
        worker.async { [self] in
            let result = operation()
            let snapshot = priority.leases
            DispatchQueue.main.async { [self] in
                busy = false; sessions = snapshot
                status = result.code == -128 ? "已取消授权。" : result.output
                if result.code != 0 && result.code != -128 { showError(result.output) }
                rebuildMenu()
            }
        }
    }
    @objc func selectTask() {
        guard !busy else { return }
        NSApp.activate(ignoringOtherApps: true)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() && $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        let panel = NSAlert()
        panel.messageText = "选择要调节的任务"
        panel.informativeText = "提高所选进程的 CPU 调度优先级，持续 30 分钟。收益取决于 CPU 争抢与应用自身调度；不会锁定频率或改变 GPU 调度。开始需管理员授权，可随时结束并恢复。"
        panel.addButton(withTitle: "开始")
        panel.addButton(withTitle: "取消")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 144))
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 28))
        picker.addItems(withTitles: apps.map { "\($0.localizedName ?? "应用")（PID \($0.processIdentifier)）" })
        let custom = NSTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 26))
        custom.placeholderString = "可选：工作进程 PID，覆盖上方应用选择"
        custom.toolTip = "大模型和剪辑应用可能由后台进程计算；可从活动监视器查找该进程 PID。"
        let level = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 28))
        level.addItems(withTitles: ["提高调度优先级（nice -5）", "更高调度优先级（nice -10）"])
        let controls = [("应用", picker as NSView), ("后台任务（可选）", custom as NSView), ("CPU 调度", level as NSView)]
        for (index, control) in controls.enumerated() {
            let y = CGFloat(2 - index) * 48
            let caption = NSTextField(labelWithString: control.0)
            caption.frame = NSRect(x: 0, y: y + 28, width: 390, height: 16)
            caption.font = NSFont.systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            control.1.setFrameOrigin(NSPoint(x: 0, y: y))
            view.addSubview(caption); view.addSubview(control.1)
        }
        panel.accessoryView = view
        guard panel.runModal() == .alertFirstButtonReturn else { return }
        let typed = custom.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = picker.indexOfSelectedItem
        let pid: Int32?
        let name: String
        if !typed.isEmpty { pid = Int32(typed); name = "进程 \(typed)" }
        else if apps.indices.contains(selected) { pid = apps[selected].processIdentifier; name = apps[selected].localizedName ?? "应用" }
        else { pid = nil; name = "" }
        guard let pid, pid > 1 else { showError("请选择应用或输入有效的工作进程 PID。"); return }
        let desired = level.indexOfSelectedItem == 0 ? -5 : -10
        perform { [self] in
            let result = priority.start(pid: pid, name: name, desired: desired)
            return result.code == 0 ? CommandResult(code: 0, output: "已调节 \(name)，设置已回读确认。") : result
        }
    }
    @objc func restoreTask(_ sender: NSMenuItem) { perform { [self] in priority.end(pid: Int32(sender.tag)) } }
    @objc func restoreAll() { perform { [self] in priority.end() } }
    @objc func removeLegacy() { perform { TaskAuthorization.removeLegacyPermission() } }
    func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "操作未通过验证"
        alert.informativeText = text
        alert.runModal()
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Mac 任务优先级 · 2.0.1 测试版"
        alert.informativeText = "手动提高指定进程的 CPU 调度优先级：提高为 nice -5，更高为 -10。只作用于所选进程，不覆盖子进程或 GPU 调度。没有 CPU 争抢时可能没有速度收益，不能保证更高频率或功耗。\n\n每次会话最长 30 分钟，可从活动任务中单独恢复或结束全部；退出本软件后由临时监督进程恢复原值。外部工具改变优先级时保留其修改。\n\n每次开始需系统管理员授权，不保存密码、不新增免密权限、不安装永久提权服务。只可选择当前账户的进程，不关闭、暂停或重启你的应用和项目。\n\n菜单关闭时不采样性能；会话监督等待系统事件，不做定时性能采样，不使用 GPU。系统电源模式、风扇及温控不由本软件修改。"
        alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) { worker.async { [self] in priority.releaseOnQuit() } }
    @objc func quitApp() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--remove-legacy-permission") {
    let result = TaskAuthorization.removeLegacyPermission()
    print(result.output)
    exit(result.code == 0 ? 0 : 1)
} else if CommandLine.arguments.contains("--self-test") {
    let priority = TaskPriority()
    guard let own = priority.inspect(getpid()), own.uid == getuid() else { fatalError("Unable to read process identity") }
    print("PASS: live process identity and CPU nice read; UID=\(own.uid), nice=\(own.nice)")
} else {
    if let identifier = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != getpid() }) { exit(0) }
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
